---
title: "ADR-0014: Autoscaling on vLLM queue depth, not GPU utilization"
---

**Status:** Accepted
**Date:** 2026-06-20

## Context

Serving runs raw vLLM behind GIE/agentgateway (ADR-0005, ADR-0013). Replica count is managed
by hand today (`make vllm-up/down`). To become a self-hosted LLM platform the serving tier needs to scale
its replicas on load. The question is **what signal** to scale on and **what mechanism** drives it.

GPU/accelerator constraints shape this: under PagedAttention vLLM holds the GPU near **100% util at
all times**, so GPU-util is a useless load signal. Request *concurrency* is also a poor proxy:
in-flight count says nothing about whether the server is keeping up. vLLM exposes a direct
saturation signal instead: **`vllm:num_requests_waiting`** (requests queued, not yet running).

This lab is single-GPU (`GPUS_ALL_REGIONS=1`) and runs **$0-idle** by design: `raw-vllm` defaults
to `replicas: 0`, the GPU node scales to zero, and Argo ignores `/spec/replicas` so `make
vllm-up/down` is the bring-up control. Any autoscaler we add must not break that cost posture.

## Decision

**Scale vLLM with KEDA on `vllm:num_requests_waiting` (Prometheus trigger), secondary
`vllm:kv_cache_usage_perc`.** This is the convergent 2026 vendor default (GKE inference
best-practices, Red Hat OpenShift AI Nov-2025, KServe v0.18 Standard-mode, vLLM production-stack).

- **Mechanism = KEDA**, not a raw HPA + custom-metrics adapter. KEDA's Prometheus scaler queries
  PromQL directly (the ServiceMonitor already lands vLLM metrics in Prometheus) and generates the
  HPA for the 1→N range, with no Prometheus Adapter / `external.metrics.k8s.io` plumbing to operate.
- **Primary signal** `sum(vllm:num_requests_waiting)`, threshold ~5/replica (AverageValue → desired
  = ceil(total_queue / 5)). **Secondary** `vllm:kv_cache_usage_perc` (KV-cache pressure; V1 rename
  of `gpu_cache_usage_perc`). **Never** scale on GPU-util.
- **KEDA operator** is a controller-only, no-cost, **auto-sync** platform app (chart 2.20.1, wave 1,
  its CRDs gate the ScaledObject). The **ScaledObject** lives with `raw-vllm` (**manual-sync**,
  wave 4) and ships **paused** (`autoscaling.keda.sh/paused: "true"`).

**Reconciling autoscaling with $0-idle:** a live ScaledObject *owns* `/spec/replicas`; an unpaused
`minReplicaCount: 1` on a GPU deployment would pin an L4 node up 24/7 (~$240/mo) and fight `make
vllm-down`. So the ScaledObject is **paused by default**: KEDA touches no replicas while paused, so
`make vllm-up/down` behave exactly as before. Autoscaling is a deliberate, session-scoped action
(`make keda-demo-up` → load test → `make keda-demo-down` → `make vllm-down`), consistent with the
manual-sync discipline for paid compute.

**Replica floor is a profile knob (ties to deployment profiles), not a fixed default:** prod `min 2` (HA) ·
dev `min 1` · cost `min 0`. True scale-to-zero (`min 0`) additionally needs the **KEDA HTTP Add-on**
(buffering proxy) because GIE returns **503 at 0 endpoints** + node min-0 + accepting multi-minute
cold start (gated on the cold-start work); deferred, not wired now.

## Alternatives considered

- **HPA + Prometheus Adapter** (`external.metrics.k8s.io`). Rejected: an extra adapter to deploy and
  operate for the same outcome KEDA gives via direct PromQL. KEDA still emits an HPA under the hood.
- **GKE custom/external metrics HPA (Stackdriver adapter).** Rejected: couples scaling to Cloud
  Monitoring + the managed adapter; we already run in-cluster Prometheus and want portability.
- **Knative / KPA (concurrency or RPS).** Rejected: concurrency/RPS are poor load proxies for LLM
  serving (a slow decode keeps concurrency low while the queue grows), and KPA pulls in Knative
  Serving, heavy for a single hot model. Queue depth is the truer saturation signal.
- **Scale on GPU utilization.** Rejected outright: PagedAttention pegs GPU-util ~100%, so it never
  reflects load.
- **llm-d Workload Variant Autoscaler (WVA).** Deferred: KV/SLO-aware, per-model scale-to-zero,
  independent prefill/decode scaling, the future power path; extends our GIE/EPP. Adopt when
  multi-model / disaggregation earns the complexity (CNCF Sandbox today). Not needed for one model.
- **Kueue for serving autoscale.** Rejected: Kueue governs *batch* admission/quota; let KEDA/HPA own
  serving replicas. They are complementary, not substitutes.

## Consequences

- Serving scales on a real saturation signal with no custom-metrics adapter to operate; the only new
  always-on component is the small KEDA controller (no GPU cost).
- $0-idle and `make vllm-up/down` are preserved because the ScaledObject is paused by default; the
  trade-off is that autoscaling is opt-in per session rather than always-on.
- Single-GPU quota caps real scale-out at 1 replica, so true **1→N** is validated on the free CPU
  sim (`llm-d-inference-sim`, which emits the same `vllm:num_requests_waiting`); on the real GPU we
  validate that KEDA reads the metric and computes scale intent. Raising the ceiling needs a GCP GPU
  quota bump.
- Scale-to-zero is **not** delivered here (needs KEDA HTTP Add-on + cold-start work); the
  floor stays a profile decision. Tripwire to watch: `vllm:num_requests_swapped > 0` (KV-cache
  thrash, a sign to scale out sooner or cap concurrency).
- Sources: KEDA on `num_requests_waiting` (KServe v0.18, Red Hat 2025-09/11), vLLM Sleep Mode,
  KEDA HTTP Add-on maturity.
