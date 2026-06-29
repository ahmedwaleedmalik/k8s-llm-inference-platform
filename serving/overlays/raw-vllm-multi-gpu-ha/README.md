# raw-vllm / multi-gpu-ha overlay

N-replica HA overlay for raw-vLLM. Kustomize overlay over
[`serving/raw-vllm`](../../raw-vllm) that changes only two things:

| Field | Base (single-GPU default) | This overlay |
|---|---|---|
| `spec.replicas` | `0` ($0-idle) | `2` |
| `spec.strategy` | `Recreate` | `RollingUpdate` (`maxSurge: 1`, `maxUnavailable: 0`) |

Everything else (image pin, model, probes, PVC, ESO secret, ServiceMonitor) is inherited verbatim.

## Gated to a multi-GPU substrate

Apply **only** on a cluster with **>=2 GPUs** (validated on the 2-GPU Vast cluster). On the default
single-GPU footprint (`GPUS_ALL_REGIONS=1`) the base's `Recreate`/`1` is the correct config — a
`RollingUpdate` surge pod could never get a second GPU and the roll would deadlock. This overlay is
**not** wired into the Argo catalog; render and apply it directly during a multi-GPU session:

```sh
kubectl apply -k serving/overlays/raw-vllm-multi-gpu-ha
```

(The catalog app `serving-core/raw-vllm` keeps `ignoreDifferences` on `/spec/replicas` so manual
scaling never shows OutOfSync; this overlay is an out-of-band, substrate-specific bring-up.)

## Why this proves the GIE EPP load-balances across N endpoints

The GIE **InferencePool is unchanged**. It selects backends by label
`app.kubernetes.io/name: raw-vllm` (`routing/gateway-api-inference/inferencepool/values-raw-vllm.yaml`)
and the EPP picks among **all** endpoints carrying that label. The two replicas from this overlay
both carry it, so they automatically become EPP backends — standing up replica #2 is sufficient to
demonstrate KV/queue-aware fan-out across N endpoints. No routing manifest changes.

## Validate on a 2-GPU cluster (C1)

1. `kubectl apply -k serving/overlays/raw-vllm-multi-gpu-ha` → two `raw-vllm` pods Ready, each on its own GPU.
2. Confirm the InferencePool/EPP sees 2 endpoints (EPP logs / `kubectl get inferencepool raw-vllm -o yaml`).
3. Drive load through the inference gateway; confirm requests spread across both pods (per-pod
   `vllm:num_requests_running` / access logs), not pinned to one.
4. `kubectl rollout restart deploy/raw-vllm -n serving` → confirm zero-downtime roll (one replica
   always Ready), which the base's `Recreate` cannot do.
