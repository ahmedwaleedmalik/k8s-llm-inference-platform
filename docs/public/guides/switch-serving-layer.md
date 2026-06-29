---
title: "Switch serving layer"
---

Three serving layers run the same vLLM engine on this platform: **raw vLLM** (`serving/raw-vllm`),
**KServe `InferenceService`** (`serving/kserve`), and **llm-d `LLMInferenceService`**
(`serving/llm-d`). They are not stacked: a model is served on one of them. This runbook is how an
operator picks the layer for a model and moves a model between them. The architecture-level comparison
is [Raw vLLM vs KServe](/architecture/serving-layers); the per-layer operational gotchas live in
[vllm-serving.md](/guides/vllm-serving), [kserve.md](/guides/kserve), and [kserve-modelcar.md](/guides/kserve-modelcar).

## Pick the layer

| Use | When | Cost |
|---|---|---|
| **Raw vLLM** | one model, one team, full control; you own rollout/scale (the benchmarked default) | you write Deployment + Service + PVC + probes by hand; no canary, no auto-ingress |
| **KServe `InferenceService`** | lifecycle/canary/scale/ingress/governance handled declaratively across many models | a control plane to run (cert-manager + controller) and opinionated defaults that fight you until known |
| **llm-d `LLMInferenceService`** | large/multi-node models needing prefill/decode disaggregation + KV-aware routing | needs >=2 GPUs to show the throughput win; runs in its own namespace with its own GIE so it does not collide with the reference routing layer |

Decision shortcut:

- Single benchmarked endpoint, minimal moving parts: **raw vLLM**.
- A fleet of models with a uniform CR, stable per-model URLs, declarative canary, native
  scale-to-zero: **KServe**.
- A model too big for one GPU, or one that needs KV-aware/disaggregated serving: **llm-d** (validated
  on the multi-GPU substrate; on a single GPU the manifest demonstrates the mechanism, with the
  throughput win observable once a second GPU is present).

## What changes between layers (same model, same engine)

| Dimension | Raw vLLM | KServe ISVC | llm-d LLMISVC |
|---|---|---|---|
| **Manifest** | Deployment + Service + PVC + probes | one `InferenceService` CR | one `LLMInferenceService` CR |
| **Namespace** | `serving` | `kserve` | `llm-d` |
| **Weights** | pre-staged PVC, initContainer, HF-offline | pre-staged PVC (`--model=/models/qwen`) or `oci://` modelcar | `hf://` URI; KServe storage stages the weights |
| **Ingress / URL** | Service; you wire the gateway/route | KServe auto-creates an HTTPRoute + stable per-ISVC URL | router (`route: {}`) generates the HTTPRoute on the isolated gateway |
| **Rollout / canary** | DIY (`Recreate`, no split) | `canaryTrafficPercent` (revision-based split) | router-managed |
| **Scale-to-zero** | manual `replicas:0` + Argo `ignoreDifferences` | native `minReplicas:0` | router/pool managed |
| **Routing** | LiteLLM -> Service (or GIE InferencePool) | gateway HTTPRoute -> predictor | bundled InferencePool + EPP (KV/prefix-aware) |
| **Prereqs** | none beyond the cluster | cert-manager + KServe controller + network controller | KServe + the `kserve-llmisvc` CRD/presets, >=2 GPUs |
| **Feature gate** | `serving-core` (always on) | `kserve: true` | `llm-d: true` (`llm-d`) |

## Feature gates and bring-up

Each layer's Argo `Application`s exist only when its feature group is enabled in
`environments/ai-dev/config.yaml`, then materialized with `make resolve-groups && make root`
(see [staged-bring-up.md](/guides/staged-bring-up)). The GPU-bearing apps are manual-sync (the cost gate):

```yaml
features:
  kserve: true             # KServe declarative serving path (serving/kserve)
  llm-d: true              # advanced disaggregated serving (serving/llm-d)
```

| Layer | Feature group | Applications | Sync |
|---|---|---|---|
| raw vLLM | `serving-core` (always on) | `raw-vllm` | manual (`make vllm-up/down` owns replicas) |
| KServe | `kserve` | `kserve` (controller), `kserve-demo` (`qwen-cpu` / `qwen-oci`) | controller auto; `kserve-demo` manual |
| llm-d | `llm-d` | `llm-d` (`qwen-llmd`) | manual |

```bash
make resolve-groups                  # after editing config.yaml features
make root PROFILE=full               # materialize the Applications for the enabled groups
```

## Move a model from raw vLLM to KServe

The same `Qwen2.5-0.5B-Instruct` is already served on both layers, so this is the worked path. Bring up
the KServe variant; the raw-vLLM Deployment is independent and stays at `replicas:0`.

1. **Confirm the gate + controller.** `kserve: true` in `config.yaml`; the `kserve` group synced
   (cert-manager + KServe controller Healthy). The Gateway (`serving/kserve/gateway.yaml`,
   `gatewayClassName: agentgateway`) must exist for the ISVC URL to resolve.
2. **Use a custom-container predictor.** `serving/kserve/inferenceservice.yaml` runs vLLM verbatim
   (container named `kserve-container`) instead of `model`+`runtime`. The `model`+`runtime` binding
   force-injects `--model=/mnt/models` and requires a `storageUri` + storage-initializer, which the
   HF-429 egress breaks ([kserve.md](/guides/kserve) §4-5). Keep `--model=/models/qwen` against the
   pre-staged `kserve-model-cache` PVC, or switch to the digest-pinned `oci://` modelcar for big models
   ([kserve-modelcar.md](/guides/kserve-modelcar)).
3. **Set an explicit `limits.cpu`.** KServe defaults a cpu limit of 1 when unset; any `requests.cpu>1`
   then makes the Deployment invalid and it never updates ([kserve.md](/guides/kserve) §3).
4. **Sync and validate** through the gateway:

   ```bash
   argocd app sync kserve-demo
   kubectl -n kserve get isvc qwen-cpu                 # READY=True
   GW=$(kubectl -n kserve get gateway kserve-ingress-gateway -o jsonpath='{.status.addresses[0].value}')
   curl -s -H "Host: qwen-cpu-kserve.example.com" http://$GW/v1/models
   ```

5. **Re-point the tenant alias (optional).** To route the LiteLLM alias to the KServe path instead of
   raw vLLM, change `api_base` in the model's `model_list` entry (`platform/litellm/values.yaml`) to the
   predictor Service (`http://qwen-cpu-predictor.kserve:80`) or the gateway, then
   `argocd app sync litellm`. The tenant-facing alias and virtual keys are unchanged.

> KServe gives native `minReplicas:0` scale-to-zero; idle-pause a running predictor with the
> `serving.kserve.io/stop` annotation ([kserve.md](/guides/kserve) §8), not `make vllm-down`.

## Move a model to llm-d

llm-d is a contained, advanced scale-out path, isolated in the `llm-d` namespace with its own
gateway/GIE, **not** a replacement for the reference agentgateway+GIE path.
`serving/llm-d/llminferenceservice.yaml` serves the same `Qwen2.5-0.5B-Instruct` with prefill/decode
disaggregation and KV-aware routing.

1. **Enable + materialize:** `llm-d: true` -> `make resolve-groups && make root PROFILE=full` so the
   `llm-d` Application exists (manual-sync, `ServerSideApply=true` for the large CRD).
2. **Confirm GPU capacity.** Disaggregation = 1 prefill GPU + 1 decode GPU. On a single GPU
   (`GPUS_ALL_REGIONS=1`) only one pool schedules, so the disaggregation/KV-routing throughput win is
   not yet observable; the manifest demonstrates the mechanism. The throughput benchmark runs on the
   2-GPU substrate (see `serving/llm-d/README.md`).
3. **Sync the path:**

   ```bash
   argocd app sync llm-d
   kubectl -n llm-d get llminferenceservice qwen-llmd
   ```

Weights come from the `hf://Qwen/Qwen2.5-0.5B-Instruct` URI (KServe's storage layer stages them), not a
hand-wired PVC like raw vLLM. The router (`scheduler: {}` + `route: {}`) creates the bundled
InferencePool + EPP and the HTTPRoute on the isolated `llm-d-gateway`.

## Switching back / tearing down a layer

Layers are independent, so "switching off" a layer is scaling its workload to $0 and (optionally)
re-pointing the LiteLLM alias back:

```bash
make vllm-down                                          # raw vLLM -> $0 (releases the GPU node)
kubectl -n kserve annotate isvc qwen-cpu serving.kserve.io/stop=true --overwrite   # KServe idle-pause
argocd app delete llm-d --yes                          # drop the llm-d path
```

To remove a whole layer's Applications, disable its feature flag (`make resolve-groups`) or delete its
catalog group; full ordered teardown (Gateways before the cluster to avoid orphaned LBs) is in
[teardown.md](/guides/teardown).
