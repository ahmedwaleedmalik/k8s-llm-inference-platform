---
title: "LiteLLM tenant gateway"
---

LiteLLM fronts the GIE gateway with an OpenAI `/v1` facade: virtual keys carry per-key $budgets,
TPM/RPM limits, and spend tracking. Chart `1.89.2`; Postgres via CloudNativePG. Argo apps:
`cloudnative-pg` (operator, wave 1), `litellm-bootstrap` (Cluster + ESO secrets, wave 3),
`litellm` (proxy, wave 4). All auto-sync (platform tier).

## 1. Prereqs: the secrets (do this first)

Create the backing values in GCP Secret Manager (see the [secret reference](/reference/secrets)):

```sh
PROJECT=<your-project>   # rewritten by `make fork-init` on a fork
printf 'sk-%s' "$(openssl rand -hex 24)" | gcloud secrets create litellm-master-key --data-file=- --project "$PROJECT"
openssl rand -hex 32 | tr -d '\n'        | gcloud secrets create litellm-salt-key   --data-file=- --project "$PROJECT"   # WRITE-ONCE
openssl rand -hex 24 | tr -d '\n'        | gcloud secrets create litellm-db-password --data-file=- --project "$PROJECT"
```

`vllm-api-key` already exists (raw-vLLM). The salt key **must never change**: it encrypts provider
keys stored in Postgres; rotating it orphans them.

## 2. Bring-up (staged)

```sh
argocd app sync cloudnative-pg                 # operator + CRDs
argocd app sync litellm-bootstrap              # Postgres Cluster + ESO secrets
kubectl -n litellm get cluster litellm-pg      # wait: STATUS "Cluster in healthy state"
kubectl -n litellm get externalsecret          # litellm-pg-app + litellm-secrets → SecretSynced
argocd app sync litellm                         # migration Job (PreSync) → proxy
kubectl -n litellm rollout status deploy/litellm
```

The migration Job (`litellm-migrations`, an Argo **PreSync hook**) applies the Prisma schema before
the proxy starts; the proxy itself runs with `DISABLE_SCHEMA_UPDATE=true` so it never self-migrates.

## 3. Validate: virtual keys + budgets

Port-forward and use the master key to mint two virtual keys with different budgets:

```sh
kubectl -n litellm port-forward svc/litellm 4000:4000 &
MASTER=$(kubectl -n litellm get secret litellm-secrets -o jsonpath='{.data.PROXY_MASTER_KEY}' | base64 -d)

# low budget (will throttle) + high budget
LOW=$(curl -s http://localhost:4000/key/generate -H "Authorization: Bearer $MASTER" \
  -H 'Content-Type: application/json' -d '{"models":["qwen-local"],"max_budget":0.01}' | python3 -c 'import sys,json;print(json.load(sys.stdin)["key"])')
HIGH=$(curl -s http://localhost:4000/key/generate -H "Authorization: Bearer $MASTER" \
  -H 'Content-Type: application/json' -d '{"models":["qwen-local"],"max_budget":5}' | python3 -c 'import sys,json;print(json.load(sys.stdin)["key"])')

# HIGH key → real completion (needs raw-vllm up: `make vllm-up`, and B2 routing synced)
curl -s http://localhost:4000/v1/chat/completions -H "Authorization: Bearer $HIGH" \
  -H 'Content-Type: application/json' \
  -d '{"model":"qwen-local","messages":[{"role":"user","content":"ping"}],"max_tokens":16}'

# LOW key → drive past $0.01 → expect HTTP 400 "budget exceeded"
# spend ledger:
curl -s http://localhost:4000/spend/logs -H "Authorization: Bearer $MASTER"
```

Success = HIGH returns a real completion, LOW throttles on budget, spend is recorded.

## 4. Gotchas

- **Salt key is write-once.** See §1. Never rotate `litellm-salt-key`.
- **`masterkeySecretName: litellm-secrets`** is set so the chart does NOT mint its own random
  master key (which would regenerate each sync and invalidate every issued virtual key).
- **DB single instance = mitigated SPOF.** `allow_requests_on_db_unavailable=true` keeps the proxy
  serving if Postgres blips (new-key/spend writes pause). HA later: bump `Cluster.spec.instances`.
- **Real output needs real GIE routing + GPU.** LiteLLM's `qwen-local` routes to the in-cluster gateway; real
  completions require `make vllm-up` and the real-routing apps synced (runbook `inference-gateway.md` §8).
- **Optional external provider:** add `ANTHROPIC_API_KEY` to GSM + the `litellm-secrets`
  ExternalSecret, then uncomment the `claude-haiku` model in `platform/litellm/values.yaml`.
- **$budgets need per-token cost (cluster-verified).** A self-hosted model has no default price, so
  without `input_cost_per_token`/`output_cost_per_token` in its `model_list` entry every call costs
  **$0** and budgets never bind. Both are set on `qwen-local`.
- **Spend is async.** LiteLLM batches per-request spend to `LiteLLM_SpendLogs` and aggregates to the
  key's `spend` a few seconds later; the budget check reads the (slightly lagging) cached spend. So a
  burst of rapid calls can briefly overshoot before the next one is rejected: enforcement is
  eventually-consistent, not per-token-exact. (Verified: budget $0.00015 → call 3 returns HTTP 429
  "Budget has been exceeded".)
- **Querying the DB:** the CNPG `postgres` container uses peer auth, so connect as the `postgres`
  superuser (`psql -U postgres -d litellm`), not `-U litellm` (which fails peer auth over the socket).
