---
title: "Inference gateway"
---

Routing layer: `routing/gateway-api-inference/`. Stack: Gateway API v1.5.0 + GIE v1.5.0
(`InferencePool` + EPP) on agentgateway v1.2.1, backed by `llm-d-inference-sim` ($0-GPU).
Argo apps (waves 1-4): `gateway-api-crds`, `agentgateway-crds`, `agentgateway`, `inference-pool`
(+ `inference-pool-model-b-stable`, `inference-pool-model-b-canary`), `inference-demo`.

## 1. Smoke test the routing

```sh
kubectl -n inference port-forward svc/inference-gateway 8080:80 &
curl -s -X POST localhost:8080/v1/completions -H 'Content-Type: application/json' \
  -d '{"model":"Qwen/Qwen3-0.6B","prompt":"hi","max_tokens":8}' -D - | grep -i x-inference-pod
```

`x-inference-pod` in the response headers = the backend pod the **EPP** chose for that request.
Fire a dozen requests and the pod varies by live load (not even round-robin): that is the
inference-aware behaviour. The Gateway also has an external LB IP
(`kubectl -n inference get gateway inference-gateway -o jsonpath='{.status.addresses}'`).

## 2. Model-aware routing: route by model name, canary by weight

Gateway API matches headers/path, never the JSON body, but OpenAI clients put the model in the
body. GIE's **Body-Based Routing (BBR)**, native in agentgateway, bridges this with an
`AgentgatewayPolicy` (`agentgateway.dev/v1alpha1`) in the `PreRouting` phase:

```yaml
spec:
  targetRefs: [{group: gateway.networking.k8s.io, kind: Gateway, name: inference-gateway}]
  traffic:
    phase: PreRouting
    transformation:
      request:
        set:
          - {name: X-Gateway-Base-Model-Name, value: string(json(request.body).model)}
```

HTTPRoute then `headers: [{type: Exact, name: X-Gateway-Base-Model-Name, value: <model>}]` per
model → its `InferencePool`. **Canary** = weighted `backendRefs` across two same-model pools
(`model-b-stable` weight 90 / `model-b-canary` weight 10). Verify:

```sh
GW=$(kubectl -n inference get gateway inference-gateway -o jsonpath='{.status.addresses[0].value}')
# route by name (model-a vs model-b vs unknown→404)
for m in Qwen/Qwen3-0.6B Qwen/Qwen2.5-1.5B-Instruct does/not-exist; do
  curl -s -m15 -o /dev/null -w "%{http_code} " -D - http://$GW/v1/completions \
    -d "{\"model\":\"$m\",\"prompt\":\"x\",\"max_tokens\":1}" | grep -i x-inference-pod; done
# canary split: fire 60 and count
for i in $(seq 60); do curl -s -D - -o /dev/null http://$GW/v1/completions \
  -d '{"model":"Qwen/Qwen2.5-1.5B-Instruct","prompt":"x","max_tokens":1}' \
  | grep -io 'vllm-sim-b-\(stable\|canary\)'; done | sort | uniq -c
```

Gotchas: passthrough CEL (no alias map) means **unknown model → 404** (no rule matches). That is
the proof routing is by name, not catch-all. A request with no `model` field errors the CEL; all
OpenAI requests carry it. Each pool runs its **own EPP** (one Deployment per `InferencePool`), so
the HTTPRoute `backendRefs[].name` must equal each pool's Helm `releaseName`.

## 3. EPP pod stuck `Pending`: `Insufficient cpu`

The `inferencepool` chart's **default EPP request is `cpu: 4`, `mem: 8Gi`** (sized for a
production EPP fronting many GPUs). On an `e2-standard-4` (4 vCPU total) it never schedules:
`0/1 nodes are available: 1 Insufficient cpu`, and the GPU pools are tainted (untolerated). Fix:
right-size in `routing/gateway-api-inference/inferencepool/values.yaml` →
`inferenceExtension.resources` (`cpu:200m / mem:256Mi`, limit `512Mi`). The EPP is
lightweight against a sim.

## 4. Gateway stays `Programmed=False` / no proxy pod

The `agentgateway` **GatewayClass is created by the controller at runtime**, not by the Helm
chart (so `helm template` shows no GatewayClass, which is expected). A `Gateway` with
`gatewayClassName: agentgateway` only binds once the agentgateway **controller** Deployment in
`agentgateway-system` is Running. Check `kubectl -n agentgateway-system get pods` and
`kubectl get gatewayclass agentgateway`. agentgateway is a **self-contained** control plane: it
does NOT need Envoy Gateway or kgateway underneath (unlike Envoy AI Gateway).

## 5. CRDs: vendored-by-reference, ServerSideApply

`gateway-api-crds` is a kustomization whose `resources` are the pinned **release-download URLs**
for Gateway API `standard-install.yaml` and GIE `manifests.yaml` (Argo's repo-server fetches them
at render). The app sets `ServerSideApply=true`; these CRDs exceed the client-side apply
annotation limit (same trap as Kueue). If the app shows transiently `Degraded`/`Missing` on first
sync, it is mid-reconcile; selfHeal converges it.

## 6. Version traps (verified against the served schema, not old examples)

- `InferencePool` is **GA**: `inference.networking.k8s.io/v1`.
- `InferenceObjective` is still **alpha**: `inference.networking.x-k8s.io/v1alpha2`
  (`spec.priority` int, higher = served first; `spec.poolRef.{group,name}`). It replaced the old
  `InferenceModel`. Don't trust v1alpha2-era `InferenceModel` examples.
- The InferencePool name = the Helm **release name** (`releaseName: vllm-sim`); the HTTPRoute
  `backendRefs[].name` and every `InferenceObjective.poolRef.name` must match it.
- HTTPRoute backendRef to a pool uses `group: inference.networking.k8s.io`, `kind: InferencePool`,
  not a Service.

## 7. Child app shows `Synced+Healthy` but on the *old* commit

Right after `git push`, a child app (e.g. `inference-demo`) can report `Synced+Healthy` while its
`status.sync.revision` is still the **previous** commit: Argo hasn't re-polled the repo yet, so
new manifests (the model-b sims) appear "synced" but aren't applied. Confirm with
`kubectl -n argocd get application <app> -o jsonpath='{.status.sync.revision}'` vs
`git rev-parse HEAD`; force a re-pull with
`kubectl -n argocd annotate application <app> argocd.argoproj.io/refresh=hard --overwrite`.
Annotating only `root` refreshes root, not necessarily every child in one pass.

## 8. Real backend (real GIE routing)

The sim pools (`vllm-sim`, `model-b-*`) live in `inference`; the **real** pool `raw-vllm` lives in
`serving` (a GIE InferencePool selects pods in its own namespace, and raw-vLLM runs in `serving`).

**Cross-namespace gotcha (verified on cluster):** agentgateway does **not** honor a `ReferenceGrant`
for a cross-namespace *InferencePool* backendRef: a route in `inference` pointing at a pool in
`serving` stays `ResolvedRefs=False / RefNotPermitted` even with a correct grant. Fix: keep the route
**same-namespace** as the pool (both in `serving`) and attach it cross-namespace to the shared
gateway via the gateway's `allowedRoutes.namespaces.from: All`. So `llm-route-real` lives in
`serving`, backendRef → `raw-vllm` (same ns), `parentRef` → `inference-gateway` (ns `inference`).
It routes model `qwen2.5-0.5b-instruct` (raw-vLLM's `--served-model-name`, the name the client must
send, not the HF id). Bring the backend up with `make vllm-up`; idle, the pool has 0 endpoints and
the route returns 503.

Apps: `inference-pool-raw-vllm` (Helm pool/EPP, ns serving, wave 3) + `inference-routing-real`
(kustomize route+objective in serving, wave 4). Smoke (auth header is forwarded to vLLM):

```sh
GW=$(kubectl -n inference get gateway inference-gateway -o jsonpath='{.status.addresses[0].value}')
KEY=$(kubectl -n serving get secret vllm-api-key -o jsonpath='{.data.api-key}' | base64 -d)
curl -s http://$GW/v1/chat/completions -H "Authorization: Bearer $KEY" \
  -H 'Content-Type: application/json' \
  -d '{"model":"qwen2.5-0.5b-instruct","messages":[{"role":"user","content":"ping"}],"max_tokens":16}'
```
