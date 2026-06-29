---
title: "ADR-0032: GuideLLM as the standard serving benchmark"
---

**Status:** Accepted
**Date:** 2026-06-23

## Context

[ADR-0003](/decisions/0003-inference-slos) sets latency/throughput SLOs and asks the question a serving platform must answer: *what is the
max sustainable request rate at which the SLOs still hold*, the latency-vs-throughput SLO frontier. The
original baseline used vLLM's built-in `vllm bench serve` over a **closed-loop** concurrency sweep
(`--request-rate inf` at `--max-concurrency` ∈ {1,2,4,8,16,32}). That harness emits the right percentiles
(TTFT, ITL, TPOT, throughput) but only *backs into* the frontier: a closed-loop client offers exactly as
much load as the server can absorb, so it never asks "at a fixed arrival rate, does the server keep up?",
which is the question that actually defines capacity-at-SLO.

GuideLLM (`vllm-project/guidellm`) is the ecosystem-standard SLO/capacity tool: it backs the Red Hat
inference-benchmark articles and `llm-d/llm-d-benchmark`. Its **open-loop** `sweep` rate-type drives a
fixed arrival rate independent of server speed, so it yields the latency-vs-throughput frontier
(max-RPS-at-SLO) directly. A Red Hat AI-Catalyst-style comparison requires the "max-RPS-at-SLO"
story, so the earlier "GuideLLM not adopted" position flips.

## Decision

**Adopt GuideLLM as the standard serving benchmark.** Its open-loop `sweep` is the SLO-frontier source
of record going forward. **Demote `vllm bench serve` to an optional, zero-dependency smoke check**, kept
because it ships inside the vLLM image (no extra pull) and gives a quick "is the endpoint alive and
roughly sane" signal, but no longer the lineage for published numbers.

**Do not maintain both as first-class.** One canonical harness avoids two divergent number sets that a
reader would have to reconcile.

- `benchmarks/guidellm-job.yaml` runs in-cluster as a Job, image `ghcr.io/vllm-project/guidellm:v0.5.0`
  (**pinned**: GuideLLM is pre-1.0 and CLI/output shapes shift across tags). `make bench-guidellm`.
- Canonical invocation: `guidellm benchmark run --target $BASE_URL --rate-type sweep --data
  'kind=synthetic_text,prompt_tokens=256,output_tokens=128' …`, matching the [ADR-0003](/decisions/0003-inference-slos) 256-in/128-out
  request shape so the frontier is comparable to the baseline's request profile.
- **Target-agnostic**, reusing the existing `bench-target` / `bench-target-auth` contract (same as the
  `vllm bench serve` Job): point it at raw-vLLM, KServe, or LiteLLM by ConfigMap; a LiteLLM virtual key
  is sourced from `bench-target-auth`. No new auth path.

### Parity gate (done before demoting `vllm bench serve`)

GuideLLM was run on the same L4 / Qwen2.5-0.5B-Instruct baseline to confirm it reports the same
qualitative shape before the older harness was demoted. Open-loop numbers differ from the closed-loop
baseline **by design** (different loop model + request shaping), so they are not expected to match
point-for-point; only the saturation behavior must agree.

**Recorded, 2026-06-23, L4 / Qwen2.5-0.5B-Instruct via KServe modelcar (vLLM v0.23.0), synthetic
256-in/128-out:**

| strategy | req/s | total tok/s | TTFT mdn | ITL mdn |
|---|---|---|---|---|
| synchronous (1 stream) | 1.3 | ~550 | 31 ms | 5.7 ms |
| sustainable (~SLO knee) | ~12 | ~5.3k | ~70 ms | ~9 ms |
| saturation (throughput) | ~15 | ~6.1k | 3.7 s (saturated) | 86 ms |

The knee matches [ADR-0003](/decisions/0003-inference-slos)'s finding: TTFT degrades first as the GPU saturates while ITL stays low until
the throughput ceiling.

## Consequences

- **+** The latency-vs-throughput SLO frontier ([ADR-0003](/decisions/0003-inference-slos)'s actual question) is read directly, not
  inferred from a closed-loop matrix.
- **+** Aligns with the ecosystem-standard tool, so forkers' numbers are comparable to published llm-d /
  Red Hat results.
- **+** Becomes the obvious harness for later multi-replica / disaggregation comparisons where
  "max-RPS-at-SLO across topologies" is the headline.
- **−** A second image to pull (mitigated: pinned dig/tag; the smoke path still needs no extra image).
- **−** GuideLLM is pre-1.0; the tag pin is load-bearing and must be bumped deliberately.
- The single-GPU GuideLLM baseline above is recorded; multi-GPU sweeps (HA + disaggregation) are tracked
  and `[needs-gpu]`.

Relates to [ADR-0003](/decisions/0003-inference-slos) (the SLOs/SLIs this measures against) and [ADR-0006](/decisions/0006-raw-vllm-vs-kserve) (the serving targets benchmarked).
Harness + how-to: `benchmarks/README.md`, benchmarking guide in the docs site.
