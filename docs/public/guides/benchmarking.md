---
title: "Benchmarking"
---

One harness measures TTFT, ITL, end-to-end latency, and throughput under load against raw vLLM,
KServe, or LiteLLM on **your** GPU. Run it to validate a new GPU, catch a regression after a config
change, or produce comparable numbers.

Harness = vLLM's built-in `vllm bench serve` (`benchmarks/job.yaml`), run as an in-cluster Job. The
recorded reference baseline + analysis lives in [`../benchmarks.md`](../benchmarks); the live view is
the **vLLM Serving** Grafana dashboard.

## What it measures

| Signal | Meaning | Watch because |
|---|---|---|
| **TTFT** | time to first token (prefill) | first SLI to degrade under load; user-perceived "responsiveness" |
| **ITL** | inter-token latency (decode) | streaming smoothness; set by continuous batching |
| **E2E** | end-to-end request latency | ≈ TTFT + (output_tokens × ITL) |
| **req/s, tok/s** | throughput | capacity; tracks GPU utilisation toward saturation |

Resource peaks (GPU util, GPU mem, KV-cache %, running/waiting) are read from the same Prometheus/DCGM
the dashboard uses; that's how you tell *compute-bound* from *memory-bound*.

## Run it (default target = raw vLLM)

```sh
make vllm-up        # bring up a GPU node + the model
make bench          # delete+apply the Job, wait, print the results table
make vllm-down      # release the GPU ($0 idle)
```

`make bench` prints a concurrency-sweep table (concurrency ∈ {1,2,4,8,16,32}, fixed 256-in/128-out,
seed 42, closed-loop). The Job prefers the raw-vllm node (`podAffinity`) so the image is cached and the
client→server hop stays on-node; the numbers reflect the server, not the network.

## Read the results

- **Find the saturation knee.** Throughput (tok/s) climbs with concurrency until GPU util pins ~100 %;
  past that, more concurrency buys throughput only by trading latency (TTFT/E2E climb). The knee is your
  practical max concurrency at an acceptable latency.
- **TTFT degrades first.** If TTFT p95 blows past your SLO before throughput plateaus, you're
  prefill-bound; shorten prompts, add replicas, or pick a faster GPU.
- **Compute- vs memory-bound.** GPU util ~100 % while KV-cache % stays low and `waiting=0` → compute is
  the wall (typical for small models); high KV-cache % / `num_requests_swapped>0` → memory is the wall
  (bigger models, long context); that's when KV-aware routing / larger GPUs matter.
- **Compare to the baseline.** Diff your table against [`../benchmarks.md`](../benchmarks) for the same
  model/shape. Large TTFT/throughput deltas on similar hardware usually mean a misconfig (wrong dtype,
  `--max-model-len`, `--gpu-memory-utilization`, no GPU/driver), not the model.

## Benchmark *your* hardware (forkers)

The harness is hardware-agnostic: run it on your own GPU and record the context so the numbers mean
something. **Always capture, alongside the table:** commit SHA, GPU model + machine type, driver/CUDA,
model + dtype, vLLM version, server args, request shape, and load pattern (see the `## Run context`
header in [`../benchmarks.md`](../benchmarks) for the exact fields). A number without that context
isn't reproducible.

To stress a bigger model or a different shape, override the request via env on the Job, e.g. longer
prompts (`--random-input-len`) or more output (`--random-output-len`): edit the `COMMON` args in
`benchmarks/job.yaml`, or add a `bench-target` ConfigMap (below) for the endpoint bits.

## Benchmark KServe or LiteLLM (same harness, one ConfigMap)

The Job defaults to raw-vllm but reads `BASE_URL` / `BENCH_MODEL` / `TOKENIZER` / `ENDPOINT` from an
optional `bench-target` ConfigMap. All three paths expose an OpenAI `/v1` endpoint, so only the target
address, model name, and (for LiteLLM) the key change.

**KServe**: hit the predictor Service directly (bypasses the gateway, measures the server):

```sh
kubectl -n serving create configmap bench-target \
  --from-literal=BASE_URL=http://qwen-cpu-predictor.kserve:80 \
  --from-literal=BENCH_MODEL=qwen2.5-0.5b \
  --dry-run=client -o yaml | kubectl apply -f -
make bench
kubectl -n serving delete configmap bench-target   # reset to raw-vllm default
```

**LiteLLM**: point at the proxy and supply a **virtual key** (it won't accept the raw-vllm key). This
benchmarks the full keys/budgets path, not just serving:

```sh
kubectl -n serving create configmap bench-target \
  --from-literal=BASE_URL=http://litellm.litellm:4000 \
  --from-literal=BENCH_MODEL=qwen-local \
  --dry-run=client -o yaml | kubectl apply -f -
kubectl -n serving create secret generic bench-target-auth \
  --from-literal=OPENAI_API_KEY=sk-<your-litellm-virtual-key> \
  --dry-run=client -o yaml | kubectl apply -f -
make bench
kubectl -n serving delete configmap bench-target secret bench-target-auth   # reset
```

> Co-location note: the `podAffinity` prefers the raw-vllm node. When benchmarking KServe/LiteLLM,
> confirm where the bench pod landed (`kubectl -n serving get pod -l app.kubernetes.io/name=vllm-bench -o wide`)
> for clean on-node numbers, co-locate with the *target's* pod or read the deltas with that in mind.

## Record the run

Append the table + full run context to [`../benchmarks.md`](../benchmarks), and watch the same signals
live on the **vLLM Serving** Grafana dashboard (`dashboards/vllm-serving-dashboard.json`).

## Caveats

- **A single-GPU setup** measures one GPU's ceiling, not multi-replica scale-out (1-GPU quota). The shapes
  are model- and GPU-specific; re-run on your model/GPU for your numbers.
- **Closed-loop** (`--request-rate inf`) measures max throughput at fixed concurrency. Open-loop
  rate/SLO-driven capacity planning ("max requests/sec at a p95 SLO") is a separate, optional tool and is
  not wired in here.
- Tear the GPU back to zero (`make vllm-down`) when done; benchmarking holds a GPU node up.
