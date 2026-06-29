---
title: "Future Roadmap"
---

A parking lot for capabilities **evaluated and deliberately deferred**. This is **not a commitment**;
it records *what* to reach for, *when* it would be worth the complexity, and *why* it isn't built now.
An item graduates out of here only when its trigger condition is met.

> For directions already taken, see [Architecture](/architecture/index) and
> [Concepts](/architecture/lessons/index). This page is the "not now, but here's the door"
> list, so a deliberate omission isn't mistaken for an oversight.

## Quick read

| Area | Current stance | Revisit trigger |
|---|---|---|
| Multi-tenancy | LiteLLM keys/budgets plus Kueue quota are enough for the current platform shape. | Tenants need their own namespaces or control planes. |
| Model delivery | OCI modelcar is the default, portable delivery path. | Large models fan out across many warm GPU nodes. |
| Observability | Prometheus, Grafana, DCGM, vLLM metrics, LiteLLM spend, and OpenCost cover the current loop. | Per-tenant prompt traces or deep LLM analytics become necessary. |
| MLOps | Serving is in scope; training, registry, eval gates, and promotion are later lifecycle work. | Model and prompt changes become a recurring PR workflow. |
| GPU density | Time-slicing is tested for GPU sharing; MPS/DRA hard isolation is not adopted yet. | Per-tenant compute/memory caps are required under multi-tenant contention. |
| Governance | NetworkPolicy, Kueue admission, SSO, and secret isolation cover the lab threat model. | Compliance or multi-team production use needs enforced baselines. |

## Multi-tenancy & isolation

| Idea | What it adds | Why deferred | Revisit when |
|---|---|---|---|
| **Capsule** (soft multi-tenancy) | Namespace-as-a-tenant: self-service namespaces, auto-propagated `ResourceQuota`/RBAC/`NetworkPolicy` across many tenant namespaces | Overkill for this platform: the tenancy boundary is the **LiteLLM layer** (virtual keys + per-key/team budgets + spend), not the K8s namespace. Tenants consume an OpenAI endpoint with a key; they don't get a namespace. Capsule's value only appears if tenants deploy **their own workloads** into the cluster (a PaaS-for-infra story, not a self-hosted LLM platform). | Tenants need to run their own in-cluster workloads, or you operate enough tenant namespaces that propagating quota/RBAC/netpol by hand is painful. |
| **vCluster** (hard multi-tenancy) | A full virtual control plane per tenant, strong isolation | Not needed for trusted internal teams; heavier than soft tenancy | A tenant is **untrusted** and needs control-plane-level isolation (true hard multi-tenancy). |

**Current baseline instead:** plain-Kubernetes per-tenant isolation: `namespace` +
`ResourceQuota` + RBAC + `NetworkPolicy`, with **LiteLLM** (keys/budgets/teams) and **Kueue** (GPU
quota fairness) as the real tenancy controls. The multi-tenancy investment goes into SSO and a
self-service key portal, where the multi-team value actually is.

## Model delivery & performance

| Idea | What it adds | Why deferred | Revisit when |
| --- | --- | --- | --- |
| **GKE model-delivery scale path** (GCS-FUSE CSI + Hyperdisk ML READ_ONLY_MANY; opt. vLLM Run:ai Model Streamer) | Fast multi-node fan-out of large weights (Hyperdisk ML up to ~2,500 nodes, ~11.9x faster loads) on GKE | Deferred. The OCI modelcar default already gives forkable, air-gap-clean delivery; this only pays off at many warm nodes + large (30-70 GB) models, is GKE-specific, and can't be exercised on a single-GPU footprint. | A warm multi-node GPU pool serves a large model and weight fan-out is the cold-start bottleneck. |
| **LMCache** (KV-cache reuse/offload) | Persists & reuses KV cache across CPU/SSD/Redis/S3 + CacheBlend non-prefix reuse → lower TTFT for shared-prefix / RAG / long-context / multi-turn | Not adopted: a serving *optimization*, not on the critical path; overlaps the GIE prefix-aware routing and is bundled by the integrated llm-d path. Optimizing before measuring. | Benchmarks show TTFT pain on a shared-prefix/RAG/long-context workload, then evaluate LMCache as the llm-d KV layer. |

## Deploy-time safety

| Idea | What it adds | Why deferred | Revisit when |
| --- | --- | --- | --- |
| **GPU-fit preflight** (model-vs-VRAM check before serving), inspired by AI Runway's "check GPU fit" | Catches the #1 serving failure (a model that exceeds GPU VRAM → silent OOM/CrashLoop or stuck-Pending) *before* deploy, with an estimate of `weights(params×dtype-bytes) + kv_cache(max_model_len, batch) + overhead` vs the GPU's memory. | Not built yet. **Kyverno (the chosen enforcement layer) can't do this generically:** at admission it sees only the pod spec. `nvidia.com/gpu: "1"` is a *count*, not VRAM GB, and param-count/dtype/max-model-len live in the model's HF `config.json`/weights, not the spec. Kyverno can introspect neither model architecture nor node VRAM, so it can only *enforce a number already computed* and stamped into an annotation. The only **generic** estimator source (any model) is fetching HF `config.json` at deploy time: a script/CI step with network, not admission. With a 0.5B model on a 24 GB L4 (fits trivially), there's nothing to catch yet. | Models large enough that fit is non-obvious (≈≥7B on L4, or any model approaching VRAM), **or** a self-service deploy path where operators pick arbitrary models. Then: a `scripts/gpu-fit.sh` reads HF `config.json` (generic) → computes the estimate → CI gate + optional pod annotation; Kyverno enforces the annotated number at admission. |

## Observability

| Idea | What it adds | Why deferred | Revisit when |
| --- | --- | --- | --- |
| **Langfuse** (self-hosted LLM tracing) | LLM-level traces, spans, and analytics across prompts/completions; v3 self-hosted, roughly an 8 GB footprint | Deferred in favor of cheap **correlation-ID propagation** (LiteLLM → gateway → vLLM), which gives the debuggable two-hop tail at near-zero cost. Standing up a trace store for one hot model is more infrastructure than the question warrants. | Trace-level analytics across many tenants is needed: per-tenant prompt/cost/latency breakdowns, not just a single request's path. |

## MLOps & data lifecycle

A whole lifecycle milestone, deferred post-publish. The platform today serves models; it does not yet
manage the lifecycle that produces and promotes them. Each piece below is real and scoped, but the
milestone as a unit waits until the platform needs lifecycle and data, not just serving.

| Idea | What it adds | Why deferred | Revisit when |
| --- | --- | --- | --- |
| **MLflow model registry** | A registry with alias-based promotion (`candidate` → `staging` → `champion`), so a model version graduates by alias rather than by re-deploy | Serving works without a registry; the modelcar digest is already the versioned artifact. A registry earns its keep once promotions are a recurring workflow, not a one-off. | Model versions cycle often enough that alias promotion beats hand-editing image digests. |
| **RAG sample** | A reference retrieval-augmented path with **pgvector** as the single default vector store (the earlier dual-vector-store idea is dropped to keep one obvious choice) | Not a serving primitive; a data-layer demo. One default (pgvector, already a Postgres dependency) avoids carrying two stores for a sample. | The platform needs a retrieval story, not just raw completions. |
| **Eval gates + LoRA demo** | `promptfoo` and `lm-eval` wired as PR gates (quality regressions block merge) plus an **Axolotl** LoRA fine-tune demo | Eval-as-a-gate only matters once model/prompt changes flow through PRs; there is no fine-tune pipeline yet to gate. | Model or prompt changes ship via PR and need an automated quality bar. |
| **Argo Workflows** (fine-tune → register → serve) | An orchestrated pipeline tying fine-tune, registry promotion, and serving into one DAG | The three stages above do not exist yet to orchestrate; orchestration is the last piece, not the first. | The fine-tune, registry, and eval pieces exist and need to run as one repeatable pipeline. |

## GPU density & sharing

**Time-slicing has been tested** for letting multiple pods share one GPU by interleaving. It is a
fairness/packing lever with **no isolation** (a noisy pod starves its neighbors), so it stays an
opt-in density tool, not a default in the single-hot-model footprint. The remaining density work below
is genuinely deferred.

| Idea | What it adds | Why deferred | Revisit when |
| --- | --- | --- | --- |
| **DRA + MPS** | Dynamic Resource Allocation with MPS for per-tenant SM and memory caps (real isolation between co-located tenants); needs a newer Kubernetes and driver | The isolation only matters under multi-tenant contention, and it carries a version floor the current substrate has not committed to. | Multi-GPU, multi-tenant contention is real and per-tenant compute/memory caps are required. |

## Cold-start reduction

| Idea | What it adds | Why deferred | Revisit when |
| --- | --- | --- | --- |
| **Cold-start lever stack** | Hyperdisk-ML weight fan-out, image-pull streaming, a node 0→1 warm buffer, and runtime sleep-mode, layered toward fast wakes | Each lever is cloud-specific or adds standing cost; the interim stance is a **warm floor of min-1 for hot models**, which sidesteps the cold path entirely for the workloads that matter. | The set of hot models outgrows a warm floor and paying for idle capacity stops being acceptable. |
| **KEDA HTTP scale-to-zero** | A buffering proxy so the gateway can hold requests at zero endpoints, enabling true `min 0` | Gated on cold start being *fast enough* that a request can wait out a wake without timing out; that condition is not met yet. | The lever stack above lands and a cold wake is within an acceptable request budget. |

## Governance & cost

| Idea | What it adds | Why deferred | Revisit when |
| --- | --- | --- | --- |
| **Kyverno PodSecurity-restricted + image signing** | The remainder of the security story beyond the shipped SR1 `NetworkPolicy` and SR2 Kueue-queue gate: a restricted PodSecurity baseline and signed-image verification | The shipped controls cover the lab threat model; a restricted baseline and signing are compliance machinery with no current auditor to satisfy. | A real multi-team compliance need (an auditor, a security review) requires an enforced baseline. |
| **Per-namespace chargeback** | Cost attribution per tenant namespace, now that OpenCost ships the underlying infrastructure-cost signal | Chargeback only means something with multiple teams to bill; the OpenCost data is there, the multi-team consumer is not. | Multiple teams share the cluster and infrastructure cost must be attributed per team. |
| **Per-user attribution beyond Open WebUI** | Extends per-user spend and rate limits to apps without a per-end-user identity today: Tabby (shared coding token) and n8n (one service virtual key). Open WebUI already attributes per SSO user. | These apps carry no end-user identity to forward, so attribution needs per-user tokens or an identity-forwarding shim; the value only appears with multiple billable users on those apps. | Tabby or n8n usage must be billed or rate-limited per user, not per app. |
| **Key portal UX polish** | Sign-out control, clearer empty state, copy-to-clipboard, and better spend/budget presentation around the shipped list/create/rotate/revoke lifecycle | The functional lifecycle is shipped in chart `0.2.0`; the remaining work is product polish, not platform wiring. | The portal becomes a regular end-user surface instead of an operator demo. |
| **Model catalog live UI** | A governed model catalog (aliases, owners, limits, cost, allowed tenants, status) sourced live from LiteLLM `/model/info`, beyond the static doc page | The static doc covers the lab's small model set; a live, queryable catalog earns its keep only with many models and tenants to govern. | The model set grows enough that a live source of truth beats a hand-maintained doc. |

## Serving correctness backlog

Small, real serving-correctness items. Each is a known gap, not a hypothetical.

| Idea | Why it matters | When to do it |
| --- | --- | --- |
| **Canary warmup-aware readiness** | A new replica reports `Running` before it is warmed, so a canary can route to a cold replica and eat the warm-up latency as user-visible tail. Gating readiness on *warmed*, not just `Running`, avoids this. | When canary or rolling updates on the serving tier route real traffic during warm-up. |
| **agentgateway warm-fallback** | The data plane targets a GA standard (Gateway API Inference Extension), so it is swappable; if it regresses, traffic should fall back cleanly. Document the Envoy / kgateway / GKE-Gateway escape hatch so a fork is never locked into a single implementation. | Before depending on agentgateway in a production posture. |
| **Backpressure coherence** | Timeout budgets must nest down the stack (client > gateway > router > vLLM); a mismatched budget retries a request the lower layer is still processing, amplifying load under stress. | When load testing surfaces retry storms or duplicated in-flight requests. |
| **Multi-LoRA per-tenant density** | Multiple LoRA adapters on one base model let many tenants share a single GPU at near-zero marginal cost per adapter. A density lever, not a correctness fix. | When per-tenant fine-tunes are common and GPU density per tenant is the constraint. |
