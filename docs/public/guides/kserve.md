---
title: "KServe"
---

Serving layer: `serving/kserve/`. KServe **v0.19.0** in **Standard (RawDeployment)** mode (no
Knative/Istio), ingress via **Gateway API on agentgateway**. Argo apps: `cert-manager` (wave 0),
`kserve-crd` (1), `kserve` (2), `kserve-demo` (4). See [Serving layers compared](/architecture/serving-layers).

## 1. Smoke test

```sh
GW=$(kubectl -n kserve get gateway kserve-ingress-gateway -o jsonpath='{.status.addresses[0].value}')
H=qwen-cpu-kserve.example.com    # KServe assigns <isvc>-<ns>.<domain>; default domain example.com
curl -s -H "Host: $H" http://$GW/v1/models
curl -s -H "Host: $H" -H 'Content-Type: application/json' http://$GW/v1/chat/completions \
  -d '{"model":"qwen2.5-0.5b","messages":[{"role":"user","content":"ping"}],"max_tokens":16}'
```

`Ready` ISVC: `kubectl -n kserve get isvc qwen-cpu`. The gateway's catch-all HTTPRoute forwards
the path to the predictor (vLLM serves `/v1/*` + `/health`).

## 2. Install prereqs: cert-manager + deployment mode

KServe webhooks need **cert-manager** (`platform/cert-manager`, v1.20.2; `crds.enabled=true`).
Set Standard mode + reuse agentgateway as the network controller (`platform/kserve/values.yaml`):
`kserve.controller.deploymentMode=Standard`, `gateway.ingressGateway.enableGatewayApi=true`,
`gateway.ingressGateway.kserveGateway=kserve/kserve-ingress-gateway`. The Gateway
(`serving/kserve/gateway.yaml`, `gatewayClassName: agentgateway`) must exist for the ISVC URL to
resolve.

## 3. KServe injects a default **cpu limit of 1**

Symptom: ISVC `PredictorReady=False ReconcileFailed`, controller logs
`Deployment ... invalid: spec.template.spec.containers[0].resources.requests: Invalid value "2":
must be less than or equal to cpu limit of 1`. KServe defaults a cpu **limit** of 1 when unset, so
any `requests.cpu>1` makes the Deployment invalid and it **never updates** (stale pod persists).
Fix: set an explicit `limits.cpu` >= your request.

## 4. `predictor.model` + runtime forces `--model=/mnt/models`

With `model.modelFormat`+`runtime`(+`storageUri`), KServe overrides the runtime's `--model` with
`/mnt/models` (the storage-initializer mount), so it *requires* a storageUri. To let vLLM use its
own `--model` (HF repo id or a local path) and skip the storage-initializer, use a
**custom-container predictor** (`predictor.containers`, container named `kserve-container`). Costs
the ServingRuntime abstraction; worth it for control.

## 5. HuggingFace 429 on the cluster egress IP → pre-stage the model

The GKE egress IP is **persistently HF-429-rate-limited** (IP-level API limit; an HF token does
*not* lift it). Both the storage-initializer and vLLM self-download fail (`429`, surfaced as
`OSError: couldn't connect to huggingface.co`). Mitigations, cheapest first:
- **Pre-stage to the cache PVC** (what we do): download the model on an un-throttled machine and
  `kubectl cp` it onto the `kserve-model-cache` PVC, then serve `--model=/models/qwen` offline.
  vLLM never touches HF. Steps: stage into a pod that mounts the PVC RW (same node if RWO), copy
  `config.json generation_config.json merges.txt model.safetensors tokenizer*.json vocab.json`.
- **HF token** (`serving/kserve/externalsecret.yaml`, ESO→GSM `hf-token`): still set, helps on a
  *non*-throttled egress; on a throttled IP it doesn't clear the 429.
- A populated PVC is also resilient: `hf_hub` falls back to cache when a revalidation HEAD 429s.
- Forkers on un-throttled egress can set `--model=Qwen/Qwen2.5-0.5B-Instruct` to self-download.

## 6. vLLM-CPU specifics

- **WorkerProc init crashes at low CPU.** `VLLM_CPU_OMP_THREADS_BIND` default `auto` needs >=2
  cores (it reserves one for the API server and binds workers to the rest); `cpu:1` leaves none →
  `WorkerProc initialization failed`. Use `cpu:2`+. **Do not set the value to `all`**: vLLM
  v0.23.0 rejects it (`ValueError: invalid literal for int(): 'all'`); leave it unset (auto) or
  give an explicit core-id list.
- `--enforce-eager`: skip torch.compile/inductor (slow + fragile on CPU).
- `--dtype=float32` (CPU has no fp16/bf16 fast path), `VLLM_CPU_KVCACHE_SPACE=2` (GiB of RAM KV
  cache). Weights load from the PVC in ~10s; full warmup ~2-4 min on `e2-standard-4`.

## 7. `Recreate` strategy + the canary constraint

Predictor `deploymentStrategy: type: Recreate` (a CPU predictor needs ~2 cores; a RollingUpdate
surge pod needs a second free 2-core slot and deadlocks `Insufficient cpu`, same single-slot
reasoning as raw-vllm's Recreate for the single GPU). **Canary** (`canaryTrafficPercent`) runs the
new revision as a *second* pod; with an **RWO** model PVC both revisions pin to one node and
2×`cpu:2` exceeds an `e2-standard-4`, so a live canary isn't feasible at $0-CPU. A real KServe
canary needs a **ReadOnlyMany** model volume (Filestore) so revisions spread across nodes. The
weighted-split concept is already proven live at the GIE layer (runbook `inference-gateway.md` §2).

## 8. Idle-pause to save cost (live action, not declarative)

Pausing is an **operational** action, kept out of the manifest so a fresh clone deploys a *running*
ISVC, not a dead one. To scale the predictor to 0 during idle breaks (model stays verified; reloads
from the PVC in ~2-3 min):

```sh
kubectl -n kserve annotate isvc qwen-cpu serving.kserve.io/stop=true --overwrite   # pause
kubectl -n kserve annotate isvc qwen-cpu serving.kserve.io/stop-                    # resume
```

The `kserve-demo` Argo app is **manual-sync** (paid GPU, see `staged-bring-up.md`), so selfHeal won't
revert a live `stop=true`: the pause holds until you next `argocd app sync kserve-demo`.

## 9. Misc

- `VirtualServiceCRDNotFound` warning → set `kserve.controller.gateway.disableIstioVirtualHost=true`
  (we route via Gateway API, not Istio).
- KServe CRDs are large → `kserve-crd` app uses `ServerSideApply=true` (same trap as Kueue/GIE).
