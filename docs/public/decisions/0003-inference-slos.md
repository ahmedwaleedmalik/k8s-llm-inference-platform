---
title: "ADR-0003: Inference SLOs and the metrics that back them"
---

**Status:** Accepted
**Date:** 2026-06-15

## Context

A serving platform needs explicit latency/throughput objectives to (a) alert on
regressions, (b) drive future autoscaling/admission decisions, and (c) answer "what
degrades first under load?". The objectives must be grounded in a measured baseline on real
hardware, not guessed, and expressed against metrics we actually scrape.

The baseline ([`docs/benchmarks.md`](../benchmarks)) is a closed-loop concurrency sweep
of `Qwen2.5-0.5B-Instruct` on one L4 (256-in/128-out), commit `8e78aaa`. Its shape:

- **Compute-bound, not memory-bound:** GPU util pins at 100 % while KV-cache peaks at ~1 %
  and nothing queues (`waiting = 0`). On a single GPU the GPU itself is the limit; adding
  replicas can't help.
- **TTFT degrades first:** TTFT p50 grows ~5× (27 → 135 ms) across concurrency 1 → 32,
  while ITL stays ~5-12 ms. Prefill contention is the leading indicator of saturation.
- **Throughput scales near-linearly to saturation:** 168 → 3773 output tok/s as util
  approaches 100 %; past that, concurrency trades latency for throughput.

## Decision

Adopt these SLIs and initial SLOs for the raw-vLLM baseline (small model, single L4). They
are deliberately set near the measured saturation knee so a breach means "approaching the
GPU's limit," and will be re-derived per model/GPU as the matrix grows.

| SLI | Metric (vLLM V1) | Objective |
|---|---|---|
| TTFT p95 | `vllm:time_to_first_token_seconds` (histogram) | < 250 ms |
| ITL p95 | `vllm:inter_token_latency_seconds` | < 20 ms |
| E2E p95 | `vllm:e2e_request_latency_seconds` | < 1.5 s (for ≤128 output tokens) |
| Saturation | `vllm:num_requests_waiting` | sustained > 0 ⇒ at capacity (shed/queue, don't scale pods on one GPU) |
| Headroom | `vllm:kv_cache_usage_perc` | watch; this model never approaches it, the signal that matters shifts to KV on larger models |

**Capacity rule of thumb:** on a single GPU, treat `num_requests_waiting > 0` (not low GPU
util) as the scale/shed trigger. GPU util at 100 % with `waiting = 0` is healthy saturation,
not an incident.

## Consequences

- Dashboards and any future alerting use these exact metric names (the V1 renames, e.g.
  `kv_cache_usage_perc`, `inter_token_latency_seconds`, are already reflected in
  `dashboards/vllm-serving-dashboard.json`).
- The SLOs are **baseline-specific**. A larger model (bigger KV per token, heavier prefill)
  will move the first bottleneck toward KV-cache/memory and raise TTFT cost; re-running the
  same harness on that model is the trigger to revise these numbers.
- These objectives inform, but do not yet implement, autoscaling/admission: that is a later
  layer (Kueue for batch admission; request-level overload handling separately).
- **2026-06-20:** the published SLO *numbers* are baseline-only (single model/GPU, no breach alerting; Alertmanager is currently disabled). Multi-replica HA serving is validated on the multi-GPU substrate, but the per-model SLO numbers and alerting still need re-deriving from that run (the harness is the same; `benchmarks.md` needs the multi-GPU figures added).
