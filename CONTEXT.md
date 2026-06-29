# CONTEXT: domain language and repository map

Canonical terms and repo layout. Use these names consistently in code, manifests, ADRs, and docs: a shared
vocabulary that keeps the codebase navigable for humans and agents. Decisions
live in `docs/public/decisions/`; this file is just the glossary.

## Core framing

- **Lab vs product.** The running cluster is a deliberately minimized **lab** (single GPU, scale-to-zero,
  0.5B model, ~$30–35/mo) used only to validate capabilities cheaply. The **product** target is a
  production-grade, HA, multi-tenant self-hosted LLM platform. Lab constraints are validation artifacts,
  not product requirements; capabilities are deferred and tracked, not designed out.
- **Substrate.** The cloud layer beneath Kubernetes: the GKE cluster, node pools, Workload Identity,
  IAM/service accounts, Artifact Registry. Owned by **OpenTofu** (ADR-0028). Never managed by Argo.
- **In-cluster lifecycle.** Everything running *inside* Kubernetes: controllers, CRDs, workloads, secret
  sync. Owned by **Argo CD** via GitOps. Never managed by OpenTofu. The substrate / in-cluster boundary is
  hard (ADR-0028).

## Request path (top to bottom)

- **Tenant edge / economics.** **LiteLLM** is the tenant-facing control plane: virtual API keys,
  per-key/team budgets, TPM/RPM limits, a spend ledger, and a single OpenAI `/v1` facade. The tenancy
  boundary is here (keys/budgets), not the Kubernetes namespace (ADR-0013).
- **Routing.** **GIE** (Gateway API Inference Extension) on the **agentgateway** data plane:
  inference-aware endpoint selection (KV-cache / queue-depth / prefix / LoRA). Key objects: **InferencePool**
  (a set of serving replicas) and **EPP** (the endpoint picker) (ADR-0005).
- **MCP gateway.** A governed egress for agent tools: one safe MCP server fronted by agentgateway with
  auth + rate-limit. Feature-gated (`mcp-gateway`), ships in the `routing` layer (ADR-0033).
- **Serving.** The model server. Default = **raw vLLM** (OpenAI-compatible). **KServe InferenceService
  (ISVC)** is the platform-managed lifecycle alternative; llm-d / `LLMInferenceService` is the scale-out
  graduation path only.
- **GPU platform.** GKE-managed NVIDIA driver / device-plugin / DCGM; **Kueue** for GPU quota admission
  (ADR-0002); **KEDA** for replica autoscaling on `vllm:num_requests_waiting` (ADR-0014).

## Delivery & operations

- **Profile.** A named, cumulative selection of layers you deploy: `platform | serving | llm-gateway |
  full`. Selected by which app-of-apps **root** you apply (`make root PROFILE=…`, ADR-0027). (`routing`
  is a layer, not a selectable profile; it ships inside `llm-gateway`/`full`.)
- **Layer.** A tier (`platform | serving | routing | llm-gateway | experience | demos`) with a per-layer
  ApplicationSet in `clusters/ai-dev/appsets/<layer>.yaml`; its child manifests live under
  `clusters/ai-dev/catalog/<group>/`. Which catalog groups are enabled is driven by `config.yaml`
  `features:` (ADR-0031).
- **Demo.** A clearly-labelled, non-production illustration (the sim-backed routing demo, the CPU KServe
  demo, example tenants). Lives in the `demos` layer; never part of the real request path.
- **Modelcar.** A model packaged as a digest-pinned OCI image, served via `oci://`; the forkable,
  air-gap-friendly model-delivery default (ADR-0016).
- **Scale-to-zero.** GPU node pool min-0 + serving replicas to 0 when idle. A *lab cost* mechanism, not a
  product default (warm pools are product-core).
- **fork-init.** `make fork-init` rewrites repo URL + GCP project across a fork from
  `environments/<env>/config.yaml`, the single source of fork config.
- **ESO.** External Secrets Operator. Materializes Kubernetes Secrets from GCP Secret Manager. Secret
  *values* never enter git or IaC state (ADR-0011).

## Repository map

| Path | What |
| --- | --- |
| `infra/gke/terraform/` | OpenTofu: the GKE cloud substrate (ADR-0028) |
| `infra/hetzner/` | OpenTofu + k3s: the second-cloud portability path |
| `clusters/ai-dev/catalog/` | Argo Application catalog, one directory per group |
| `clusters/ai-dev/appsets/` | per-layer ApplicationSets; enabled groups driven by `config.yaml` `features:` (ADR-0031) |
| `platform/`, `serving/`, `routing/`, `experience/`, `workloads/` | Helm values + manifests the catalog apps point at |
| `environments/ai-dev/config.yaml` | single source of fork config |
| `bootstrap/` | Argo CD install + repo credential |
| `docs/public/decisions/` | decisions (the "why") |
| `docs/public/guides/` | operational how-to (the Guides section) |
| `scripts/` | `tofu.sh`, `doctor.sh`, `config-check.sh`, `fork-init.sh`, `wait-profile.sh`, `smoke-profile.sh` |
| `benchmarks/`, `dashboards/` | GuideLLM serving benchmarks (ADR-0032); Grafana dashboards |
