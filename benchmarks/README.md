# benchmarks

Load-testing an OpenAI-compatible serving endpoint and recording the results. The standard harness is
GuideLLM (`make bench-guidellm`), which sweeps the latency-vs-throughput SLO frontier; vLLM's built-in
`vllm bench serve` (`make bench`) stays as an optional zero-dep smoke. Both default to `serving/raw-vllm`
and point at KServe or LiteLLM via an optional `bench-target` ConfigMap.

For the full how-to (including reading results and the three targets), see [`../docs/public/guides/benchmarking.md`](../docs/public/guides/benchmarking.md).

## GuideLLM — the standard serving benchmark (ADR-0032)

`make bench-guidellm` (`guidellm-job.yaml`, image `ghcr.io/vllm-project/guidellm:v0.5.0`) runs an
**open-loop `sweep`** that yields the latency-vs-throughput SLO frontier (max-RPS-at-SLO) directly.
Same target-agnostic `bench-target`/`bench-target-auth` contract as the vLLM-bench job below. `vllm
bench serve` (`job.yaml`, `make bench`) is demoted to an optional zero-dep smoke.

**Recorded — 2026-06-26, raw-vLLM on 1x NVIDIA T4 (`n1-standard-4`, spot) / Qwen2.5-0.5B-Instruct
(float16), vLLM v0.23.0, GuideLLM v0.5.0 open-loop `sweep`, synthetic 256-in/128-out, 30s per
strategy.** Raw artifact: [`results/2026-06-26-t4-qwen2.5-0.5b/report.json`](results/2026-06-26-t4-qwen2.5-0.5b/report.json).

| strategy / rate | req/s | err% | TTFT p50/p95/p99 (ms) | ITL p50/p95/p99 (ms) | out tok/s | $/1k-req |
|---|---|---|---|---|---|---|
| synchronous (1 stream) | 1.2 | 0.0 | 36 / 44 / 58 | 6.0 / 6.1 / 6.4 | 161 | 0.1216 |
| constant ~4/s | 3.9 | 0.0 | 50 / 62 / 67 | 6.5 / 6.6 / 6.6 | 505 | 0.0385 |
| constant ~7/s | 6.6 | 0.0 | 51 / 64 / 75 | 7.3 / 7.5 / 7.6 | 848 | 0.0228 |
| constant ~10/s | 9.2 | 0.0 | 57 / 72 / 93 | 9.0 / 9.4 / 9.5 | 1186 | 0.0163 |
| constant ~12/s | 11.8 | 0.0 | 60 / 82 / 128 | 11.1 / 11.5 / 11.6 | 1513 | 0.0127 |
| constant ~15/s (knee) | 14.3 | 0.0 | 67 / 96 / 130 | 12.3 / 13.1 / 13.4 | 1844 | 0.0105 |
| constant ~18/s | 16.8 | 0.0 | 75 / 117 / 195 | 14.6 / 15.0 / 15.1 | 2159 | 0.0089 |
| constant ~21/s | 19.1 | 0.0 | 81 / 124 / 177 | 18.3 / 19.1 / 19.3 | 2455 | 0.0079 |
| constant ~24/s | 21.2 | 0.0 | 101 / 201 / 299 | 22.2 / 22.7 / 22.8 | 2732 | 0.0071 |
| throughput (saturated) | 23.5 | 0.0 | 7696 / 9544 / 14454 | 65.7 / 72.9 / 73.0 | 3005 | 0.0064 |

Clean 0% error across the whole sweep. The SLO knee is ~15-18 req/s (TTFT p99 <=195 ms, ITL ~13-15
ms); past ~21 req/s the achieved rate falls behind the target and TTFT p99 climbs (299 ms at the
~24/s point). The unbounded `throughput` strategy reaches 23.5 req/s / 3.0k out tok/s only by letting
TTFT saturate to 7.7-14.5 s. `$/1k-req` amortizes GPU `$0.54/hr` (`n1-standard-4` $0.19 + T4 $0.35,
on-demand list, us-central1) over the achieved req/s.

T4/float16 fallback: L4 spot capacity was unavailable (`GCE out of resources`, us-central1-a/b/c) at
run time and T4 has no BF16, so this run is NOT directly comparable to the L4/BF16 closed-loop
baseline in [`../docs/public/benchmarks.md`](../docs/public/benchmarks.md). Open-loop
sweep numbers differ from closed-loop by design (request shape + loop model); GuideLLM is the lineage
going forward.

## Recording standard + raw-JSON artifacts

Every recorded run captures the full standard, not just p50/p95:

- **p50 / p95 / p99** for TTFT and ITL — p99 is the tail users actually feel; medians hide it.
- **Error rate** — successful vs errored requests per rate (a fast-but-failing run isn't fast).
- **Cost/hr** — GPU $ amortization. `make bench-guidellm` prints `$/1k-req` from `GPU_COST_PER_HR`
  (default `0.85` = `g2-standard-4` L4 on-demand, us-central1; override per GPU/region via the
  `bench-target` ConfigMap). cost/1k-req = (`GPU_COST_PER_HR`/3600)/`req/s`×1000.

**Raw-JSON convention** — commit the harness's `report.json` under
`benchmarks/results/<date>-<gpu>-<model>/` (e.g. `benchmarks/results/2026-06-26-t4-qwen2.5-0.5b/`),
so the recorded tables above link to reproducible raw artifacts. The Job emits the trimmed JSON
(per-request logs dropped, bearer token redacted) to its log between `GUIDELLM_REPORT_BEGIN`/`_END`
markers (kubectl cp cannot reach a completed pod); copy it out with the `kubectl logs … | sed`
command the Job prints. Set `GPU_SLUG` / `MODEL_SLUG` in `bench-target` to name the directory for
non-default runs.

## Run

```sh
make vllm-up     # bring a GPU node + the model up
make bench       # delete+apply the Job, wait for completion, print the results table
make vllm-down   # release the GPU
```

`job.yaml` runs in-cluster as a Job, *preferring* the vLLM node (`podAffinity`) so the
container image is cached and the client→server hop stays on-node — the numbers reflect the
server, not the network (preferred, not required, so it still schedules for non-raw-vllm
targets). Target is read from the optional `bench-target` ConfigMap (`BASE_URL` / `BENCH_MODEL`
/ `TOKENIZER` / `ENDPOINT`), defaulting to raw-vllm. The Bearer token defaults to the
`vllm-api-key` Secret; for a LiteLLM virtual key, override via the optional `bench-target-auth`
Secret (`OPENAI_API_KEY`).

## Matrix

Closed-loop (`--request-rate inf`) at `--max-concurrency` ∈ {1, 2, 4, 8, 16, 32}, fixed
256-token input / 128-token output (`--ignore-eos` so output length is exact), seed 42.
`num_prompts` scales with concurrency (capped at 320) so each level runs enough requests
for stable percentiles.

## Recorded runs

See [`docs/public/benchmarks.md`](../docs/public/benchmarks.md) for the results
table and analysis, and the **vLLM Serving** Grafana dashboard (`../dashboards/vllm-serving-dashboard.json`) for the
same signals live (TTFT/ITL/E2E percentiles, token throughput, running/waiting, KV-cache,
GPU util/mem). Each recorded run captures the full context — commit SHA, GPU type, model,
vLLM/K8s/driver/CUDA versions, request shape, concurrency — per the benchmarking standard.
