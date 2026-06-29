---
title: "Glossary"
---

Canonical terms, used consistently across the code, manifests, and docs.

## Framing

**Reference deployment vs production**
: The default deployment is deliberately minimal: single GPU, scale-to-zero, a 0.5B model,
  ~$30-35/mo, so the whole platform can be exercised cheaply. The same architecture runs HA on
  multi-GPU (validated on a multi-GPU substrate: 2-replica zero-downtime rolling, EPP fan-out across N
  endpoints) without rearchitecting; the small footprint is a configuration, not a constraint.

**Substrate**
: The cloud layer beneath Kubernetes: cluster, node pools, identity, IAM, image registry. Owned by
  **OpenTofu**, never by Argo.

**In-cluster lifecycle**
: Everything running inside Kubernetes: controllers, CRDs, workloads, secret sync. Owned by
  **Argo CD** via GitOps. The substrate / in-cluster boundary is hard.

## Request path

**LiteLLM**
: Tenant-facing control plane: virtual API keys, per-key/team budgets, TPM/RPM limits, a spend
  ledger, one OpenAI `/v1` facade. The tenancy boundary lives here, not at the namespace.

**GIE** (Gateway API Inference Extension)
: Inference-aware endpoint selection (KV-cache / queue-depth / prefix / LoRA) on the **agentgateway**
  data plane. Key objects: **InferencePool** (a set of serving replicas) and **EPP** (endpoint
  picker).

**Serving**
: The model server. Default = **raw vLLM** (OpenAI-compatible). **KServe `InferenceService`** is the
  platform-managed lifecycle alternative; **llm-d `LLMInferenceService`** is the integrated, opt-in
  disaggregated (prefill/decode) + KV-aware serving path for large/multi-node models (feature-gated
  `llm-d: true`, default-off, needs >=2 GPUs). See
  [Serving layers compared](/architecture/serving-layers).

**GPU platform**
: NVIDIA driver / device-plugin / DCGM (managed on GKE; the NVIDIA GPU Operator off GKE); **Kueue**
  for GPU quota admission; **KEDA** for replica autoscaling on `vllm:num_requests_waiting`.

## Delivery & operations

**Profile**
: A named, cumulative selection of layers you deploy: `platform | serving | llm-gateway | full`.
  Selected by `make root PROFILE=…`. See [Make targets](/reference/make-targets).

**Layer**
: A directory under `clusters/<env>/layers/{platform,serving,routing,llm-gateway,demos}` holding the
  Argo Application manifests for that tier.

**Demo**
: A clearly-labelled, non-production illustration (CPU KServe demo, example tenants). Lives in the
  `demos` layer; never part of the real request path.

**Modelcar**
: A model packaged as a digest-pinned OCI image, served via `oci://`. The forkable, air-gap-friendly
  model-delivery default.

**Scale-to-zero**
: GPU node pool min-0 + serving replicas to 0 when idle. The cost mechanism that makes an idle
  endpoint free.

**fork-init**
: `make fork-init` rewrites repo URL + cloud project across a fork from
  `environments/<env>/config.yaml`, the single source of fork config.

**ESO** (External Secrets Operator)
: Materializes Kubernetes Secrets from a cloud secret manager. Secret *values* never enter git or
  IaC state.
