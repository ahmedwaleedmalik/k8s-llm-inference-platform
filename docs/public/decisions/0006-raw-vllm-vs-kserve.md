---
title: "ADR-0006: Serving layer: raw vLLM vs KServe `InferenceService` vs `LLMInferenceService`"
---

**Status:** Accepted
**Date:** 2026-06-18

## Context

`serving/raw-vllm` ([ADR-0003](/decisions/0003-inference-slos) benchmarks) is a hand-rolled Deployment+Service+PVC: full control,
but every operational concern (rollout, canary, autoscale-to-zero, model lifecycle, URL/ingress,
multi-model governance) is ours to wire. The question for a platform: when do we hand that to a
serving controller, and which one? KServe is CNCF-incubating and the de-facto K8s model-serving
control plane. As of v0.19 it ships **two** CR families that are easy to conflate (§9):

- **`InferenceService` + `ServingRuntime`** (`serving.kserve.io/v1beta1`): the classic path. The
  ISVC declares a model; a ServingRuntime (or a custom container) serves it; KServe reconciles a
  Deployment/Service, an ingress route, autoscaling, and canary rollout.
- **`LLMInferenceService`** (newer, ~v0.18+): an LLM-specific CR that natively embeds **llm-d +
  GIE** (disaggregated prefill/decode, KV-aware routing, prefix caching).

## Decision

**Core scope: classic `InferenceService` with a custom vLLM container, RawDeployment (Standard) mode.**
Keep `raw-vllm` as the control benchmark; add `serving/kserve` serving the *same* model
(`Qwen2.5-0.5B-Instruct`, *same* vLLM `v0.23.0`) so the comparison is engine-identical (raw on
GPU, KServe on CPU while GPU is stocked out). Ingress via Gateway API on our existing
**agentgateway** (no Istio). **`LLMInferenceService` was kept out of the core comparison path**: it embeds llm-d+GIE,
which overlaps the routing layer we already built ([ADR-0005](/decisions/0005-inference-aware-routing)); folding it into the core path
would have duplicated the agentgateway/GIE work. It is since integrated and tested as its own
isolated disaggregated-serving path (`serving/llm-d/`), not part of the core raw-vLLM-vs-KServe
comparison.

Use a **custom-container predictor** (`predictor.containers`), not `model`+`runtime`: KServe's
model+runtime binding force-injects `--model=/mnt/models` and therefore *requires* a `storageUri`
+ storage-initializer; a custom container runs verbatim so vLLM controls its own model path. (This
costs the ServingRuntime abstraction; documented in the runbook.)

## When raw vLLM vs KServe (the takeaway)

- **Raw vLLM** when: one model, one team, you want full control and minimal moving parts, and you'll
  own rollout/scale yourself. It's the right call for a single benchmarked endpoint ([ADR-0003](/decisions/0003-inference-slos)).
- **KServe `InferenceService`** when: you want the *platform* to own model lifecycle: declarative
  rollout + **canary** (`canaryTrafficPercent`), scale-to-zero, a stable URL/ingress per model, and
  a consistent multi-model contract. The cost is a control plane (controller + cert-manager) and
  KServe's opinions (see consequences).
- **`LLMInferenceService`** when (advanced-inference stage): large/multi-node models needing disaggregated serving,
  KV-aware routing, prefix caching, i.e. llm-d territory.

## Consequences

- **+** Same model serves raw and via KServe; **verified**: ISVC `Ready`, `GET /v1/models` →
  `qwen2.5-0.5b`, `POST /v1/chat/completions` → 200 (`system_fingerprint vllm-0.23.0`) through the
  agentgateway. KServe adds the lifecycle/ingress/rollout layer raw-vllm lacks.
- **+** Reused agentgateway as KServe's Gateway-API ingress: one gateway spans GIE routing and
  KServe serving; no Istio.
- **−** New prereqs: **cert-manager** (webhook certs) + the KServe controller.
- **−** KServe injects opinionated defaults that fight you (all → runbook `kserve.md`): a default
  **cpu limit of 1** (invalidates `requests.cpu>1`), an Istio VirtualString path unless
  `disableIstioVirtualHost=true`, and the model+runtime `/mnt/models` injection above.
- **−** **Canary not live-demoed** at $0-CPU: the new revision is a second predictor pod; our model
  on an **RWO** PVC pins both revisions to one node and 2×`cpu:2` vLLM-CPU pods exceed an
  `e2-standard-4`. The weighted-split concept is already proven live at the GIE layer ([ADR-0005](/decisions/0005-inference-aware-routing),
  90/10). A live KServe canary needs a ReadOnlyMany model volume (Filestore), deferred with the advanced-inference stage.
  - **2026-06-20:** KServe-native canary is configured but not live-demoed only because RWO pins both revisions to one node. PRODUCT TRIGGER = >1 model version in prod AND a ReadOnlyMany model volume.

## Follow-up: model delivery at scale

This work exposed **model delivery** as its own decision: HF self-download is fragile (the cluster
egress IP is HF-429-rate-limited even with a token), so we pre-staged the model onto a PVC and load
it offline. At scale the options are: per-pod HF pull, a shared **RWX** cache, KServe
**LocalModelCache** (node-local pre-pull DaemonSet, v0.17+), or **OCI "modelcar"** (`oci://`
weights-in-image, immutable, air-gapped-friendly). Decide deliberately
when large models / many replicas / air-gap actually arrive; modelcar is favored for a
forkable air-gapped platform.

## Update 2026-06-20: KServe promoted to model-delivery substrate

The deferred follow-up above is resolved by [ADR-0016](/decisions/0016-model-delivery): **OCI modelcar (digest-pinned `oci://`) is the
default model-delivery primitive**, and **KServe now owns model delivery** (modelcar + later
LocalModelCache are KServe-native; raw-vLLM stays the simple/benchmark endpoint). The custom-container
objection in the Decision **dissolves**: modelcar symlinks the weights to **`/mnt/models`**, so the old
"model+runtime force-injects `/mnt/models`" complaint is moot: a custom container reads `/mnt/models`
directly with no storage-initializer copy. New ISVC `serving/kserve/inferenceservice-modelcar.yaml`
(`qwen-oci`, GPU). **GPU validation pending** (the proof that closes this ADR's CPU-only gap is the
model-delivery-at-scale deliverable; runbook `kserve-modelcar.md`). See [ADR-0016](/decisions/0016-model-delivery).

## Addendum 2026-06-23: KServe LocalModelCache DROPPED (with the OCI modelcar default)

The model-delivery follow-up above listed **LocalModelCache** (KServe's node-local pre-pull DaemonSet,
v0.17+) as a scale option alongside the OCI modelcar. With modelcar settled as the default ([ADR-0016](/decisions/0016-model-delivery)),
LocalModelCache is **dropped**, for two grounded reasons:

1. **No `oci://` source.** LocalModelCache pre-pulls from a `storageUri` (HF / object storage / PVC). The
   modelcar delivers weights as an `oci://` artifact resolved by the injected modelcar sidecar +
   init-container, not by KServe's storage-initializer: there is no `storageUri` for LocalModelCache to
   pre-pull. The two delivery mechanisms do not compose.
2. **Scale-to-zero evicts the node-warm cache.** This lab scales the GPU node to zero when idle, which
   deletes the node *and* any node-local cache on it, so a node-warm pre-pull buys nothing here. (Per
   [ADR-0000](/decisions/0000-scope)'s north star this is a lab *validation caveat*, not a product verdict: a real warm multi-node
   pool is exactly where node-warm caching pays off. The drop is "not viable **with this delivery default
   on this footprint**," not "node caching is useless.")

**Decision: dropped, documented.** The modelcar (immutable, digest-pinned, air-gap-clean, layer-cached by
the container runtime on a warm node) is the delivery substrate; node-local pre-pull is not pursued on
top of it. Revisit only if a future default reintroduces a `storageUri`-based delivery path on a warm
pool. Tracked as A12 / C3 (dropped). See [ADR-0016](/decisions/0016-model-delivery), [ADR-0000](/decisions/0000-scope).

## References

- `serving/kserve/`, runbook `kserve.md`, `docs/raw-vllm-vs-kserve.md`. KServe
  v0.19.0 (`serving.kserve.io/v1beta1`); cert-manager v1.20.2; vLLM `v0.23.0` (CPU). Supersedes the
  original ADR-006 stub.
