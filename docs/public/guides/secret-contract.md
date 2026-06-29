---
title: "Secret contract"
---

Secret values are never committed and never stored in OpenTofu state. This contract lists the external
secret **names** a forker must seed before the matching profile/feature can be fully healthy.

`make doctor PROFILE=...` checks the required GCP Secret Manager entries and the Kubernetes Secrets ESO
materializes from them.

## Runtime secrets (ESO → GCP Secret Manager)

| Profile / flag | Layer | External name | Kubernetes Secret | Required | Purpose |
|---|---|---|---|---|---|
| `serving` | serving | `vllm-api-key` | `serving/vllm-api-key` | yes | raw-vLLM `/v1/*` auth; reused upstream by LiteLLM |
| `serving` | serving | `hf-token` | `kserve/hf-token` | no | gated Hugging Face model pulls for optional KServe demos |
| `llm-gateway` | llm-gateway | `litellm-master-key` | `litellm/litellm-secrets` | yes | LiteLLM admin/master key |
| `llm-gateway` | llm-gateway | `litellm-salt-key` | `litellm/litellm-secrets` | yes | LiteLLM encryption salt; write once, never rotate casually |
| `llm-gateway` | llm-gateway | `litellm-db-password` | `litellm/litellm-pg-app` | yes | CloudNativePG app-user password |
| `llm-gateway` | llm-gateway | `litellm-grafana-ro-password` | `litellm/litellm-grafana-ro`, `monitoring/grafana-datasource-litellm` | yes | Grafana read-only spend dashboard credential |
| `features.identity` | platform | `dex-admin-hash` | `dex/dex-secrets` | flag-gated | bcrypt hash of the static Dex admin password; `make seed-secrets` mints it (runbook `sso-dex.md`) |
| `features.identity` | platform | `dex-oauth2-proxy-client-secret` | `dex/dex-secrets`, `oauth2-proxy/oauth2-proxy-secrets` | flag-gated | Dex ↔ oauth2-proxy OIDC client secret (SSO; runbook `sso-dex.md`) |
| `features.identity` | platform | `oauth2-proxy-cookie-secret` | `oauth2-proxy/oauth2-proxy-secrets` | flag-gated | oauth2-proxy session-cookie encryption |
| `features.dns` / DNS-01 | platform | `cloudflare-api-token` | `external-dns/cloudflare-api-token`, `cert-manager/cloudflare-api-token` | flag-gated | external-dns record writes + cert-manager DNS-01 |

**flag-gated** = required only when the named flag in `environments/<env>/config.yaml` is on (`features.identity`,
`features.dns`; both default `false`). These are *not* asserted by `make doctor`; it validates the `serving` and
`llm-gateway` profiles only.

## Bootstrap / IaC credentials (not ESO-materialized)

These authenticate tooling, not in-cluster workloads, so they are not read through a `ClusterSecretStore`.

| Name | Where stored | Consumed by | Purpose |
|---|---|---|---|
| Argo CD repo cred | env → `make argocd-repo` (K8s Secret only) | Argo CD | private-fork repo pull (PAT + username) |
| `dex-admin-password` | GCP Secret Manager plus `secrets/dex-admin-password` | `make credentials` / operator login | retrievable copy of the Dex static-admin password; Dex itself consumes only `dex-admin-hash` |
| `hcloud-token` | GCP Secret Manager | `infra/hetzner/terraform/` (deferred) | Hetzner Cloud API token for the `hcloud` Terraform provider / CSI / CCM. Read via `HCLOUD_TOKEN` env or a `google_secret_manager_secret_version` data source at apply time; never in git/state. Robot user+password for the dedicated GPU box is a separate, not-yet-seeded credential. |

Private GitHub forks need an Argo CD repo credential (created from env, not from Secret Manager):

```sh
export ARGOCD_REPO_PAT=<fine-grained-PAT-contents-read-only>
export ARGOCD_REPO_USERNAME=<github-user>
make argocd-repo
```

## Seed required values

```sh
export PROJECT=<your-project>

# serving + llm-gateway (required for those profiles)
openssl rand -hex 24 | tr -d '\n' | gcloud secrets create vllm-api-key --data-file=- --project "$PROJECT"

printf 'sk-%s' "$(openssl rand -hex 24)" | gcloud secrets create litellm-master-key --data-file=- --project "$PROJECT"
openssl rand -hex 32 | tr -d '\n'        | gcloud secrets create litellm-salt-key --data-file=- --project "$PROJECT"
openssl rand -hex 24 | tr -d '\n'        | gcloud secrets create litellm-db-password --data-file=- --project "$PROJECT"
openssl rand -base64 24 | tr -d '\n'     | gcloud secrets create litellm-grafana-ro-password --data-file=- --project "$PROJECT"
```

```sh
# features.identity (SSO): generate
openssl rand -hex 32    | tr -d '\n' | gcloud secrets create dex-oauth2-proxy-client-secret --data-file=- --project "$PROJECT"
openssl rand -hex 16    | tr -d '\n' | gcloud secrets create oauth2-proxy-cookie-secret --data-file=- --project "$PROJECT"

# features.dns / DNS-01: paste a token minted in the Cloudflare dashboard
printf '%s' '<cloudflare-api-token>' | gcloud secrets create cloudflare-api-token --data-file=- --project "$PROJECT"

# Hetzner portability: paste a token minted in the Hetzner Cloud Console (Security → API Tokens)
printf '%s' '<hcloud-token>' | gcloud secrets create hcloud-token --data-file=- --project "$PROJECT"
```
