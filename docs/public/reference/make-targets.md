---
title: "Make targets"
---

## Deployment profiles

A **profile** is a cumulative selection of layers, applied with `make root PROFILE=…` (default
`platform`). Each profile is a superset of the one before: you widen, you don't switch.

| `PROFILE` | Layers applied | Adds |
|---|---|---|
| `platform` | `platform` | GitOps base: GPU platform, Kueue, observability, secrets |
| `serving` | `platform` + `serving` | raw vLLM / KServe serving |
| `llm-gateway` | `platform` + `serving` + `routing` + `llm-gateway` | GIE routing + LiteLLM tenant gateway |
| `full` | all of the above + `demos` | example tenants and demos |

```bash
make root PROFILE=serving      # platform + serving
make wait  PROFILE=serving     # block until auto-sync apps are Synced+Healthy
make smoke PROFILE=serving     # profile smoke checks (serving runs the vLLM smoke)
```

Run `make argocd-repo` first while the repo is private (registers the Argo CD repo credential).

## Make targets

`make help` lists every target with its one-line description; the tables below group the ones you
run most.

### Cloud substrate (OpenTofu, paid resources)

| Target | What |
|---|---|
| `tf-init` / `tf-validate` / `tf-plan` | initialize, validate, plan the GKE root |
| `tf-apply` | apply the cloud substrate (**costs money**; `AUTO_APPROVE=1` for non-interactive/CI) |
| `tf-destroy` | destroy the substrate (read the teardown runbook first) |
| `tf-fmt` | check OpenTofu/Terraform formatting (the CI format gate) |
| `tf-credentials` | print the `gcloud get-credentials` command from TF output |

### Fork & config

| Target | What |
|---|---|
| `fork-init` | propagate `environments/$(CLUSTER)/config.yaml` (repo URL + GCP project) across the repo |
| `config-check` | validate config propagation and tfvars drift |
| `resolve-groups` | resolve `config.yaml` `features:` into `groups.generated.yaml` (chains the four resolvers below) |
| `resolve-profile` / `resolve-secret-store` / `resolve-gpu` / `resolve-guardrails` | resolve the profile (LiteLLM + CNPG HA overlays), the ESO `ClusterSecretStore`, the GPU stack (`gpu_stack` → gpu-operator group + DCGM scrape target), and the guardrails overlay |

### GitOps bring-up

| Target | What |
|---|---|
| `require-kube` | validate + print the dedicated cluster target (`./kubeconfig`); the gate every cluster command runs first |
| `bootstrap` | install Argo CD on the repo's dedicated cluster (`./kubeconfig`; pinned chart) |
| `argocd-repo` | create/update the Argo CD repo credential (private repo) |
| `seed-secrets` | seed the internal random secrets (LiteLLM/vLLM/Dex/oauth2-proxy/DB) into the backend, idempotent; prints the external ones you must supply |
| `reset-dex-admin` | rotate a lost Dex static-admin password, persist password+hash in GSM, force ESO refresh/restart Dex |
| `root` | apply the `platform` AppProject + app-of-apps roots for `PROFILE` |
| `wait` / `smoke` / `doctor` | wait for sync · run smoke checks · validate prerequisites |
| `verify` | end-to-end platform check (GitOps + economics + budget-429 + serving + edge/SSO), plain pass/fail |
| `seed-experience` | (optional) manually re-mint Open WebUI's experience secret from live LiteLLM; normally the in-cluster `litellm-keys` Job mints both apps' keys automatically |
| `argocd-password` / `argocd-ui` | print admin password · port-forward the UI to `localhost:8080` |
| `credentials` | collate operator credentials into the gitignored `secrets/credentials.local.md` (SSO is the real path) |

### Serving & GPU (cost-sensitive)

| Target | What |
|---|---|
| `vllm-up` / `vllm-down` | scale raw vLLM to 1 (brings up an L4, **costs**) / to 0 ($0 idle) |
| `vllm-smoke` | send an authenticated OpenAI chat request to raw vLLM |
| `gpu-smoke` | run the `nvidia-smi` GPU smoke Job (verifies the GPU stack; triggers a GPU node, scales back to 0) |
| `keda-demo-up` / `keda-demo-down` | un-pause / re-pause the raw-vLLM KEDA ScaledObject (load-test only) |
| `modelcar-build` | build + push the OCI modelcar, print the `@sha256` digest to pin |
| `bench` | run the vLLM concurrency-sweep benchmark Job (after `vllm-up`) |
| `bench-guidellm` | run the GuideLLM SLO-frontier sweep Job (standard serving benchmark; after `vllm-up`) |
| `guardrails-smoke` | prove the LiteLLM guardrails: PII masked + prompt-injection blocked (needs `features.guardrails: true` synced) |

### Cost control

| Target | What |
|---|---|
| `pause` | pause to $0: release Gateway LBs, destroy the substrate with tofu, audit orphans (destructive; Secret Manager values survive) |
| `resume` | resume from a paused (destroyed) cluster: tofu apply + bootstrap + platform base |

### Docs

| Target | What |
|---|---|
| `docs-serve` | serve the docs site locally with live reload (Mintlify, `http://localhost:3000`) |
| `docs-build` | validate the docs site (broken-link check, same as CI) |

## Fork configuration

`environments/<env>/config.yaml` is the single source of fork config: repo URL, cloud project,
domain, DNS provider. Edit it, then `make fork-init` rewrites the repo to match. Secret *values*
never live here; they come from a cloud secret manager via External Secrets Operator.
