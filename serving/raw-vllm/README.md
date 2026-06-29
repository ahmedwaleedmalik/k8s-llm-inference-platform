# raw-vllm

OpenAI-compatible LLM serving — a pinned [vLLM](https://github.com/vllm-project/vllm)
Deployment serving a small model on a GPU node, fronted by a ClusterIP Service. This is
the base serving layer; the Prometheus scrape here feeds latency/throughput dashboards and
load-test benchmarks.

## What's here

| File | Purpose |
|---|---|
| `deployment.yaml` | vLLM V1 server (`vllm/vllm-openai:v0.23.0`), model `Qwen/Qwen2.5-0.5B-Instruct`, 1×GPU. Default `replicas: 0`. |
| `service.yaml` | ClusterIP `:8000` — OpenAI-compatible `/v1/*` + `/metrics` + `/health`. |
| `pvc.yaml` | 20Gi RWO model cache (`HF_HOME`) so a warm node skips the HuggingFace re-pull. |
| `deployment.yaml` | Reads the shared `vllm-api-key` Secret — vLLM enforces it on every `/v1/*` request. |
| `servicemonitor.yaml` | Prometheus scrape of vLLM `/metrics`. |

Synced by Argo CD (`clusters/ai-dev/catalog/serving-core/raw-vllm.yaml`, namespace `serving`).

## Cost model — default off

`replicas: 0` means **no GPU node by default** ($0 idle — never leave a GPU running). Argo
CD `ignoreDifferences` + `RespectIgnoreDifferences=true` on `/spec/replicas` let you scale
manually without selfHeal reverting it. A session:

```sh
make vllm-up      # scale to 1 → GPU node provisions → model loads
make vllm-smoke   # authenticated OpenAI chat request, asserts a completion
make vllm-down    # scale to 0 → node released
```

## GPU scheduling

The pod requests `nvidia.com/gpu: 1` and tolerates the GPU taint but pins **no** accelerator
type, so the scheduler/autoscaler uses whichever GPU pool has capacity. The OpenTofu root creates
the scale-to-zero GPU pool (`gpu-l4` by default); switch tfvars to a T4 pool when L4 is stocked out
in `us-central1-a`. The 0.5B model fits both (L4 23GB / T4 16GB).

`strategy: Recreate` (not RollingUpdate): only one GPU is available
(`GPUS_ALL_REGIONS=1`), so a rolling surge pod could never get a second GPU and the roll
would deadlock.

## Prerequisite — the API key (once)

The Deployment reads `VLLM_API_KEY` from a shared ESO-provisioned Secret owned by the
`serving-secrets` app. Populate the backing value in Secret Manager once (keyless, same
pattern as the rest of the platform):

```sh
openssl rand -hex 24 | tr -d '\n' | gcloud secrets create vllm-api-key \
  --data-file=- --project ai-lab
```

Until this exists the `vllm-api-key` ExternalSecret stays `SecretSyncError` and the pod
won't start — by design (no secret values in git).

## Why these choices

- **vLLM V1, pinned** — float nothing. V1 renamed metrics (`kv_cache_usage_perc`,
  `inter_token_latency_seconds`); dump live `/metrics` before building dashboards on them.
- **0.5B model** — fits any of the GPUs with room to spare and cold-starts fast; the point
  is to prove the serving contract (GitOps → endpoint → auth → metrics), not model size.
- **`--gpu-memory-utilization=0.6`, `--max-model-len=8192`** — bound KV-cache allocation;
  a conservative starting point for later tuning.
- **Raw vLLM, not KServe** — the raw-vLLM-vs-KServe tradeoff is captured separately in an ADR.

## Portability note: non-GKE / k3s GPUs

On GKE the device plugin injects the GPU into the pod under the default runtime. On a self-managed cluster
(k3s + nvidia-container-toolkit) the GPU is only injected for pods with `runtimeClassName: nvidia` — without
it vLLM fails `Failed to infer device type`. Add it via an overlay on non-GKE substrates; do **not** add it
to this base manifest (GKE has no `nvidia` RuntimeClass, so it would break the reference path). The PVC
omits `storageClassName`, so it inherits whatever the cluster's default StorageClass is (`standard-rwo`
on GKE, `local-path` on k3s) — no substrate edit needed. Proven on 2x RTX 3090 / k3s.
