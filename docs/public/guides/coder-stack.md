---
title: "Coding assistant"
---

Bringing up the coding assistant: `coder-chat` (Qwen2.5-Coder-7B-Instruct-AWQ), `coder-fim`
(Qwen2.5-Coder-1.5B base), and the Open WebUI / Tabby front-ends, behind the LiteLLM gateway
with budgeted virtual keys. The GPU Deployments ship `replicas: 0` ($0 idle); you bring up one
at a time and tear down to $0 after.

> **One GPU = one model at a time.** The reference deployment runs `GPUS_ALL_REGIONS=1` (a single L4). `coder-chat`
> and `coder-fim` each request a whole `nvidia.com/gpu`, so they cannot run concurrently until GPU
> time-slicing or a second GPU lands. Validate chat, scale it to 0, then validate FIM.

## Prerequisites

- The `llm-gateway` layer is synced: LiteLLM (`litellm` ns) + its CNPG Postgres are Ready, and the
  `vllm-api-key` Secret exists in `serving` (shared upstream key, created by the `raw-vllm` app).
- The `coder-chat` and `coder-fim` Argo apps exist (manual-sync GPU apps, sync-wave 4), deployed but
  `replicas: 0`. `open-webui` and `tabby` auto-sync (sync-wave 5) once the `litellm-keys` Job has
  minted their keys.

## 1. Mint virtual keys

The front-ends authenticate to LiteLLM with **virtual keys**, not the master key. Mint one per
client, scoped to the models it needs and capped with a `$budget`: this is the metering that makes
it "as-a-service". Keys are minted at deploy and kept **out of git**.

The `litellm-keys` Job already mints a default unscoped key for Open WebUI and Tabby automatically, so
they work out of the box. The commands below mint **scoped, budgeted** keys instead; because the Job
keeps any existing valid key, a key you mint here is preserved on the next sync.

```bash
MASTER=$(kubectl -n litellm get secret litellm-secrets -o jsonpath='{.data.PROXY_MASTER_KEY}' | base64 -d)
kubectl -n litellm port-forward svc/litellm 4000:4000 &   # background

# Open WebUI key: chat + fim + embeddings
curl -s -X POST http://127.0.0.1:4000/key/generate \
  -H "Authorization: Bearer $MASTER" -H "Content-Type: application/json" \
  -d '{"key_alias":"open-webui","models":["coder-chat","coder-fim","embeddings"],"max_budget":5.0,"budget_duration":"30d"}' \
  | python3 -c 'import sys,json;print(json.load(sys.stdin)["key"])'

# Tabby key: fim + embeddings only
curl -s -X POST http://127.0.0.1:4000/key/generate \
  -H "Authorization: Bearer $MASTER" -H "Content-Type: application/json" \
  -d '{"key_alias":"tabby","models":["coder-fim","embeddings"],"max_budget":5.0,"budget_duration":"30d"}' \
  | python3 -c 'import sys,json;print(json.load(sys.stdin)["key"])'
```

The `model_name` aliases (`coder-chat`, `coder-fim`, `embeddings`) are defined in
`platform/litellm/values.yaml` `proxy_config.model_list` and route direct to the per-model Services
(single replica; add GIE InferencePools when they go multi-replica).

## 2. Bring up `coder-chat` and validate the chat path

```bash
kubectl -n serving scale deploy/coder-chat --replicas=1   # provisions the L4 node
kubectl -n serving wait --for=condition=Ready pod -l app.kubernetes.io/name=coder-chat --timeout=1200s
```

Cold start is ~10 min on a fresh node: node provision + ~10 GB vLLM image pull + ~5 GB AWQ weight
download (the initContainer pre-stages weights so the server runs `HF_HUB_OFFLINE`, see
[`vllm-serving.md`](/guides/vllm-serving)). The model-cache PVC keeps weights across restarts.

Smoke it: direct (proves the pod) and through a virtual key (proves the gateway + metering):

```bash
VLLM_KEY=$(kubectl -n serving get secret vllm-api-key -o jsonpath='{.data.api-key}' | base64 -d)
kubectl -n serving port-forward svc/coder-chat 18000:8000 &

# direct: served-model-name is qwen2.5-coder-7b-instruct
curl -s http://127.0.0.1:18000/v1/chat/completions -H "Authorization: Bearer $VLLM_KEY" \
  -H "Content-Type: application/json" \
  -d '{"model":"qwen2.5-coder-7b-instruct","messages":[{"role":"user","content":"reverse a string in python, code only"}],"max_tokens":40,"temperature":0}'

# via vkey: tenant-facing alias is coder-chat, on the LiteLLM port-forward from step 1
curl -s http://127.0.0.1:4000/v1/chat/completions -H "Authorization: Bearer <OPEN_WEBUI_VKEY>" \
  -H "Content-Type: application/json" \
  -d '{"model":"coder-chat","messages":[{"role":"user","content":"hi"}],"max_tokens":8}'
```

## 3. Deploy the front-ends (CPU, run alongside the GPU model)

Both are CPU-only and schedule on the default pool, so deploy them while the GPU model boots.

```bash
# Open WebUI: OPENAI_API_KEY = the minted vkey; WEBUI_SECRET_KEY = random session signer.
kubectl -n experience create secret generic openwebui-secrets \
  --from-literal=OPENAI_API_KEY="<OPEN_WEBUI_VKEY>" \
  --from-literal=WEBUI_SECRET_KEY="$(openssl rand -hex 32)" \
  --dry-run=client -o yaml | kubectl apply -f -
kubectl apply -k experience/open-webui

# Tabby: substitute the vkey into config.toml (kept as __LITELLM_VKEY__ placeholder in git).
TABBY_VKEY="<TABBY_VKEY>"
kubectl kustomize experience/tabby | sed "s|__LITELLM_VKEY__|$TABBY_VKEY|g" | kubectl apply -f -
```

Smoke Open WebUI → gateway → coder-chat using the app's own runtime env (no UI automation needed;
the UI is a shell over `OPENAI_API_BASE_URL`):

```bash
kubectl -n experience exec deploy/open-webui -- sh -c \
  'curl -s -H "Authorization: Bearer $OPENAI_API_KEY" $OPENAI_API_BASE_URL/models'
# → lists exactly the vkey-scoped models: coder-chat, coder-fim, embeddings
```

## 4. Swap to `coder-fim` and validate FIM

Scale chat to 0 to free the GPU, then bring up FIM on the same node:

```bash
kubectl -n serving scale deploy/coder-chat --replicas=0
kubectl -n serving wait --for=delete pod -l app.kubernetes.io/name=coder-chat --timeout=120s
kubectl -n serving scale deploy/coder-fim --replicas=1
kubectl -n serving wait --for=condition=Ready pod -l app.kubernetes.io/name=coder-fim --timeout=600s
```

**FIM hits raw `/v1/completions`, never `/v1/chat/completions`**: the chat endpoint applies the chat
template and mangles the FIM control tokens. The **client** formats the prompt with the Qwen FIM
tokens; there is no server flag:

```bash
kubectl -n serving port-forward svc/coder-fim 18001:8000 &
curl -s http://127.0.0.1:18001/v1/completions -H "Authorization: Bearer $VLLM_KEY" \
  -H "Content-Type: application/json" -d '{
    "model":"qwen2.5-coder-1.5b",
    "prompt":"<|fim_prefix|>def add(a, b):\n    return <|fim_suffix|>\n<|fim_middle|>",
    "max_tokens":16,"temperature":0}'
# → completes the middle: "a + b"
```

Tabby is the completion server; the IDE speaks Tabby's protocol and Tabby calls the gateway as a
`vllm/completion` backend → `coder-fim` (so keys/budgets cover Tabby→vLLM). Verify the keyed
leg from inside the pod:

```bash
kubectl -n experience exec deploy/tabby -- sh -c '
  VKEY=$(grep -m1 api_key /data/config.toml | sed "s/.*= *\"//; s/\"//")
  curl -s -X POST http://litellm.litellm.svc.cluster.local:4000/v1/completions \
    -H "Authorization: Bearer $VKEY" -H "Content-Type: application/json" \
    -d "{\"model\":\"coder-fim\",\"prompt\":\"<|fim_prefix|>def add(a,b):\n    return <|fim_suffix|>\n<|fim_middle|>\",\"max_tokens\":16}"'
```

> **Tabby auth:** Tabby 0.31 gates **all** its HTTP endpoints (incl. `/v1/health`) behind a
> registration token created on first-run in its web UI, so IDE→Tabby setup is a manual step, and
> the Deployment uses a `tcpSocket` readiness probe (an unauthenticated `httpGet /v1/health` always
> 401s and the pod never goes Ready).
> Tabby Enterprise can also show a native OIDC sign-in option after an OAuth credential is configured
> in Tabby's DB-backed Integrations > SSO UI. This platform pre-registers a Dex `tabby` client for
> that flow, but does not put gateway forward-auth in front of Tabby because it breaks IDE Bearer-token
> traffic.

## 4b. Agent model (tool-calling): `coder-agent`

Same one-model-at-a-time pattern (`serving/coder-agent`, Qwen2.5-Coder-14B-Instruct-AWQ, served with
`--enable-auto-tool-choice --tool-call-parser hermes`). Register it in LiteLLM at runtime (no values
edit needed, `store_model_in_db: true`), mint a scoped vkey, and drive a tool loop:

```bash
UPSTREAM=$(kubectl -n litellm get secret litellm-secrets -o jsonpath='{.data.UPSTREAM_API_KEY}' | base64 -d)
curl -X POST http://127.0.0.1:4000/model/new -H "Authorization: Bearer $MASTER" -H "Content-Type: application/json" \
  -d "{\"model_name\":\"coder-agent\",\"litellm_params\":{\"model\":\"openai/qwen2.5-coder-14b-instruct\",
       \"api_base\":\"http://coder-agent.serving.svc.cluster.local:8000/v1\",\"api_key\":\"$UPSTREAM\",
       \"input_cost_per_token\":0.0000005,\"output_cost_per_token\":0.0000015}}"
```

> **Two traps:**
> - **Host RAM caps model size, not VRAM.** The 32B-AWQ tier (18 GB weights) OOM-loads on the
>   `g2-standard-4` GPU node (16 GB RAM): vLLM stages weights through host RAM. Use 14B on this host,
>   or bump the GPU pool to `g2-standard-8` (32 GB RAM) for 30B+.
> - **`tool_choice:auto` is unreliable on Qwen2.5-Coder.** It emits tool calls as free-form text
>   (`<tools>{…}</tools>` / ```json blocks), not the hermes `<tool_call>` tag, so vLLM returns empty
>   `tool_calls`. `tool_choice:"required"` (guided decoding) forces a correct call; the clean fix is a
>   proper Qwen2.5 tool chat-template via `--chat-template`.

## 5. Confirm metering, then tear down to $0

Per-key spend is the "as-a-service" proof; read it back through the master key:

```bash
curl -s -H "Authorization: Bearer $MASTER" http://127.0.0.1:4000/key/info \
  -G --data-urlencode "key=<OPEN_WEBUI_VKEY>" \
  | python3 -c 'import sys,json;d=json.load(sys.stdin)["info"];print("spend $%.6f / budget $%s, models %s"%(d["spend"],d["max_budget"],d["models"]))'
```

Tear everything back to $0 (drains the L4 + any scaled-up default node):

```bash
kubectl -n serving scale deploy/coder-chat deploy/coder-fim deploy/coder-agent --replicas=0
kubectl -n experience scale deploy/open-webui deploy/tabby --replicas=0
pkill -f "kubectl.*port-forward"
```

The GPU node drains ~10 min after the last GPU pod exits; the cluster returns to baseline cost.
