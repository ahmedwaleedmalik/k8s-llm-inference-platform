---
title: "Change models"
---

Two day-2 operations on the raw-vLLM serving path: (A) change the model an existing endpoint serves,
and (B) stand up a brand-new model endpoint. `serving/coder-chat` is the worked "added model" example
to copy from. Both paths end at the same place: a budgeted, keyed model behind the LiteLLM `/v1`
facade. The contrast between serving layers (raw vLLM vs KServe vs llm-d) is in
[Switch the serving layer](/guides/switch-serving-layer); this guide stays on the raw-vLLM path.

## The model contract (what every served model wires)

A served model on this path is five things, all in `serving/<model>/`:

| Piece | File | What it sets |
|---|---|---|
| **Engine + args** | `deployment.yaml` | `--model`, `--served-model-name`, quantization, context, GPU/CPU resources |
| **Pre-staged weights** | `deployment.yaml` initContainer | offline-first HF snapshot to the cache PVC |
| **Weight cache** | `pvc.yaml` | one RWO PVC per model on the cluster default StorageClass (no RWO contention) |
| **In-cluster endpoint** | `service.yaml` | OpenAI `/v1` Service the gateway/LiteLLM routes to |
| **Tenant registration** | `platform/litellm/values.yaml` `model_list` | the keyed/budgeted tenant alias |

The `--served-model-name` is the engine-facing name (what `GET /v1/models` returns and what a direct
request sends in `"model"`). The LiteLLM `model_name` is the tenant-facing alias. Keep them distinct:
clients hit the alias, the gateway routes to the served name.

---

## A. Change the model an existing endpoint serves

Use this to swap the weights/args of an endpoint that already exists (for example, move `coder-chat`
to a different Qwen tier). The Service, PVC, and gateway wiring stay; only the engine args and the
pre-staged weights change.

### 1. Edit the engine args

In `serving/<model>/deployment.yaml`, change the model id (both the initContainer snapshot and the
serving `--model`) and the served name. Re-check that the new weights fit the GPU and host RAM:

```yaml
initContainers:
  - name: prestage-weights
    command:
      - python3
      - -c
      - |
        from huggingface_hub import snapshot_download as d
        m = "Qwen/Qwen2.5-Coder-3B-Instruct-AWQ"   # new model id
        try:
            d(m, local_files_only=True)
        except Exception:
            d(m)
containers:
  - name: vllm
    args:
      - --model=Qwen/Qwen2.5-Coder-3B-Instruct-AWQ   # must match the snapshot id
      - --served-model-name=qwen2.5-coder-3b-instruct
      - --quantization=awq_marlin
      - --gpu-memory-utilization=0.9
      - --max-model-len=16384
```

> **Two sizing traps (see [coder-stack.md](/guides/coder-stack) and the [model catalog](/reference/model-catalog)):**
> - **Host RAM caps model size, not VRAM.** vLLM stages weights through host RAM, so a model whose
>   weights exceed the GPU node's RAM OOM-loads even if it fits VRAM. The 14B-AWQ tier (18 GB) needs a
>   `g2-standard-8` (32 GB RAM); 7B-AWQ fits `g2-standard-4`.
> - **A bigger model needs a bigger PVC.** If the new weights exceed the PVC, bump
>   `resources.requests.storage` in `pvc.yaml` (an already-bound PVC cannot shrink; growing it is fine).

### 2. Re-stage the weights

The serving container runs `HF_HUB_OFFLINE=1`, so it will only boot if the new weights are already on
the cache PVC. The initContainer handles this automatically on the next pod start: a warm cache
contacts Hugging Face zero times; a cache that lacks the new model falls back to a one-time online
pull, then serves offline. The GKE egress IP is HF-429-rate-limited, so if the online
fallback fails, pre-stage out-of-band (download on an un-throttled machine and `kubectl cp` onto the
PVC, see [kserve.md](/guides/kserve) §5).

### 3. Update the tenant registration

If `--served-model-name` changed, update the matching `model_list` entry in
`platform/litellm/values.yaml` so the alias still routes:

```yaml
- model_name: coder-chat                              # tenant alias unchanged
  litellm_params:
    model: openai/qwen2.5-coder-3b-instruct           # = the new served-model-name
    api_base: http://coder-chat.serving.svc.cluster.local:8000/v1
    api_key: os.environ/UPSTREAM_API_KEY
    input_cost_per_token: 0.0000005
    output_cost_per_token: 0.0000015
```

> **A per-token cost is required.** A self-hosted model has no default price; omit the cost fields and
> every call computes `$0` and budgets never bind. Set illustrative prices (or your GPU amortization).

### 4. Commit, sync, bring up

Serving apps are manual-sync (the cost gate, see [staged-bring-up.md](/guides/staged-bring-up)), so a commit
does not deploy a GPU pod. After committing the manifest + values change:

```bash
argocd app sync coder-chat litellm                   # roll the new template + re-render LiteLLM
kubectl -n serving scale deploy/coder-chat --replicas=1
kubectl -n serving wait --for=condition=Ready pod -l app.kubernetes.io/name=coder-chat --timeout=1200s
```

The Deployment uses `strategy: Recreate` (one GPU, no surge slot), so the old pod terminates before the
new one schedules. First boot on a new model re-stages weights and re-captures CUDA graphs (slow).

### 5. Validate, then scale to $0

```bash
VLLM_KEY=$(kubectl -n serving get secret vllm-api-key -o jsonpath='{.data.api-key}' | base64 -d)
kubectl -n serving port-forward svc/coder-chat 18000:8000 &
curl -s http://127.0.0.1:18000/v1/models -H "Authorization: Bearer $VLLM_KEY"   # -> the new served name
kubectl -n serving scale deploy/coder-chat --replicas=0                          # back to $0 idle
```

---

## B. Add a new model endpoint

Use this to stand up a model that does not exist yet. `serving/coder-chat` is the reference: copy its
four manifests, rename, and wire it into LiteLLM and the GitOps catalog.

### 1. Create the manifest directory

Copy the closest existing model as the template (`coder-chat` for a GPU chat model, `embeddings` for a
CPU model), then rename the resources. A new model `coder-mini` (illustrative):

```bash
cp -r serving/coder-chat serving/coder-mini
```

Edit each file in `serving/coder-mini/`:

- **`pvc.yaml`**: rename the PVC (`coder-mini-model-cache`); one PVC per model so chat/fim/raw-vllm
  never contend on a single RWO volume. Size `requests.storage` to the weights.
- **`deployment.yaml`**: rename `metadata.name`, the `app.kubernetes.io/name` label (used by the
  selector, the Service, and `wait`), the initContainer model id, the serving `--model` /
  `--served-model-name`, and the `claimName` on the `model-cache` volume. Keep the shared
  `vllm-api-key` secret reference (one key for the whole `serving` namespace) and the
  `HF_HUB_OFFLINE=1` / `TRANSFORMERS_OFFLINE=1` offline env.
- **`service.yaml`**: rename `metadata.name` + label; keep `port: 8000`, `targetPort: http`.
- **`kustomization.yaml`**: no path edits needed (it references the three files by relative name);
  it reuses the `vllm-api-key` ExternalSecret created by the `raw-vllm` app.

Keep `replicas: 0` (a new GPU model starts at $0 idle) and `strategy: Recreate` (single GPU).

### 2. Register it in LiteLLM

Add a `model_list` entry in `platform/litellm/values.yaml` pointing at the new Service. This is what
makes the model keyed and budgeted (the "as-a-service" contract):

```yaml
- model_name: coder-mini                              # tenant-facing alias
  litellm_params:
    model: openai/qwen2.5-coder-3b-instruct           # = served-model-name
    api_base: http://coder-mini.serving.svc.cluster.local:8000/v1
    api_key: os.environ/UPSTREAM_API_KEY              # shared serving key
    input_cost_per_token: 0.0000005
    output_cost_per_token: 0.0000015
```

A new alias is not reachable by an existing virtual key until that key's `models` list includes it;
re-mint or scope keys per [coder-stack.md](/guides/coder-stack) §1. To register a model at runtime without
a values edit, LiteLLM's `store_model_in_db: true` allows `POST /model/new` (the `coder-agent` pattern,
[coder-stack.md](/guides/coder-stack) §4b); the committed `model_list` is the durable, reviewable path.

### 3. Wire it into the GitOps catalog

An Argo `Application` per model makes it exist in the cluster. Copy the existing one and re-point its
`path`:

```bash
cp clusters/ai-dev/catalog/coding-assistant/coder-chat.yaml \
   clusters/ai-dev/catalog/coding-assistant/coder-mini.yaml
```

Edit `coder-mini.yaml`: set `metadata.name`, `source.path: serving/coder-mini`, and the
`ignoreDifferences` Deployment `name` to `coder-mini` (so `make vllm-up/down`-style replica scaling
never shows OutOfSync). Keep manual-sync (`RespectIgnoreDifferences=true`, no `automated`), the cost
gate for a GPU workload.

The `coding-assistant` group is gated by the `coding-assistant: true` feature flag in
`environments/ai-dev/config.yaml`. The ApplicationSet (`clusters/ai-dev/appsets/serving.yaml`) recurses
the group's `catalogPath`, so a new `Application` file in an enabled group's directory is picked up
automatically; no appset edit is needed. If you add the model under a disabled group, enable the flag
and run `make resolve-groups` first (see [staged-bring-up.md](/guides/staged-bring-up)).

### 4. Apply, sync, bring up, validate

```bash
make root PROFILE=serving                             # materialize the new Application
argocd app sync coder-mini litellm                    # deploy the model app + re-render LiteLLM
kubectl -n serving scale deploy/coder-mini --replicas=1
kubectl -n serving wait --for=condition=Ready pod -l app.kubernetes.io/name=coder-mini --timeout=1200s
```

Smoke it direct (proves the pod) and through a budgeted virtual key (proves the gateway + metering),
then scale back to $0:

```bash
VLLM_KEY=$(kubectl -n serving get secret vllm-api-key -o jsonpath='{.data.api-key}' | base64 -d)
kubectl -n serving port-forward svc/coder-mini 18000:8000 &
curl -s http://127.0.0.1:18000/v1/chat/completions -H "Authorization: Bearer $VLLM_KEY" \
  -H "Content-Type: application/json" \
  -d '{"model":"qwen2.5-coder-3b-instruct","messages":[{"role":"user","content":"ping"}],"max_tokens":8}'
kubectl -n serving scale deploy/coder-mini --replicas=0
```

> **One GPU = one model at a time.** The reference deployment runs `GPUS_ALL_REGIONS=1` (a single L4).
> Each GPU model requests a whole `nvidia.com/gpu`, so a new GPU model cannot run concurrently with
> another until GPU time-slicing or a second GPU lands. Scale one down before bringing the next up.

## After adding a model

- Record it in the [model catalog](/reference/model-catalog) (backend, GPU, context, cost, eval).
- [Benchmark it](/guides/benchmarking) on your GPU and capture the run context.
- Tear the GPU back to $0 (`make vllm-down` or `scale --replicas=0`) when done; an idle GPU bills.
