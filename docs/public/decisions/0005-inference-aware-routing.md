---
title: "ADR-0005: Inference-aware routing (GIE) and the gateway implementation"
---

**Status:** Accepted
**Date:** 2026-06-16

## Context

A plain L7 load balancer (round-robin / least-conn / ring-hash) is structurally blind to what
makes an LLM replica slow. vLLM latency is driven by **per-replica live state** (KV-cache
occupancy, the running/waiting queue, prefix-cache hits), none of which an HTTP LB can see. So an
LB will happily send a request to a replica whose KV-cache is full while another sits idle,
spiking TTFT. It also can't express LLM-shaped intent: route by **model/adapter name** (carried
in the request *body*, not the path/header), split traffic across model versions, or admit
**interactive** traffic ahead of **batch** under contention.

The **Gateway API Inference Extension (GIE)** addresses exactly this: an `InferencePool` (GA at
`inference.networking.k8s.io/v1`) groups model-server pods, and an **Endpoint Picker (EPP)**,
a gRPC ext-proc the gateway calls per request, picks the endpoint using live vLLM metrics. We
need a Gateway API data plane that implements GIE.

This is a distinct layer from [ADR-0002](/decisions/0002-kueue-quota-admission) (Kueue = *job admission/quota*, not per-request routing).
Kueue decides *whether a batch job starts*; GIE decides *which replica a live request hits*.

## Options (gateway implementation)

1. **Istio (1.28+).** Confirmed `InferencePool v1` support, GIE chart has first-class
   `provider.name=istio`, most mature. But it's a full service mesh, heavy for a single
   inference gateway, and we explicitly do not want Istio here.
2. **kgateway (2.1).** Supports `InferencePool v1`, **but its Envoy-based inference path is
   deprecated, removal in 2.2**; kgateway steers AI/inference to agentgateway. Pinning it is a
   dead-end. Rejected on version-discipline grounds.
3. **Envoy AI Gateway (0.7).** Native GIE *plus* multi-provider + token/key management. But it
   requires an Envoy Gateway control plane underneath (two layers), is pre-1.0, and lags GIE
   releases. Its real value is the **multi-tenant AI gateway**, a multi-tenant-gateway concern, not the core serving path.
4. **LiteLLM.** Not a Gateway API / InferencePool implementation at all; its "load" awareness is
   its own observed request counters/latency, **never live vLLM KV/queue metrics**. It is an
   API-level multi-provider proxy (virtual keys, budgets, chargeback), a multi-tenant-gateway tool, wrong
   layer for GIE.
5. **agentgateway (1.2.1).** Self-contained Gateway API provider (no separate control plane),
   post-1.0, native `InferencePool v1` + EPP, `$0-GPU` sim quickstart, vendor-neutral. It is the
   forward path kgateway routes inference toward.

## Decision

Use **GIE v1.5.0** (`InferencePool` v1, EPP via the upstream `inferencepool` Helm chart) on
**agentgateway v1.2.1** as the gateway data plane (`provider.name=none`; agentgateway discovers
the pool). Routing chain: `Gateway(class=agentgateway) → HTTPRoute → InferencePool → EPP →
vLLM pods`. `InferenceObjective` (`inference.networking.x-k8s.io/v1alpha2`) expresses
interactive>batch priority.

**Model-aware routing + version canary.** OpenAI clients carry the model in the request *body*,
which Gateway API cannot match on. We use GIE's **Body-Based Routing (BBR)**, implemented natively
by agentgateway as an `AgentgatewayPolicy` (`agentgateway.dev/v1alpha1`) in the `PreRouting`
phase: a CEL transform (`string(json(request.body).model)`) lifts the model name into the
`X-Gateway-Base-Model-Name` header. HTTPRoute then matches that header per model → its own
`InferencePool` (one pool/EPP per model). Passthrough (no LoRA→base alias map) means an unknown
model matches no rule and gets a clean **404**, proof the routing is genuinely by model name, not
a catch-all. Version rollout is **weighted `backendRefs`** (standard Gateway API) across two pools
of the same model (`model-b-stable:90 / model-b-canary:10`), so each split target still gets the
EPP's inference-aware endpoint pick. This rejects routing the split at the Service layer (loses
EPP awareness) and a single multi-version pool (can't weight versions independently).

Rationale: leanest correct fit for the core serving path (one Helm install, no mesh, no second control plane),
on a non-deprecated path, and it **doubles as the multi-tenant gateway**: agentgateway
also does multi-provider LLM routing, per-key auth (JWT/OPA), RBAC, and rate limiting.
If the multi-tenant gateway needs OSS per-tenant budgets/chargeback (agentgateway *virtual keys* are Solo.io Enterprise),
**LiteLLM slots in front** of agentgateway for exactly that. So this choice advances the later
goal instead of discarding work.

## Consequences

- **+** EPP picks the least-loaded endpoint per request, verified distributing 12 requests 3/2/7
  across 3 replicas (load-weighted, not round-robin) at `$0-GPU` on the `llm-d-inference-sim`.
- **+** Model-aware routing verified: `Qwen3-0.6B`→model-a pool, `Qwen2.5-1.5B`→model-b pool,
  unknown model→404; the model-b version canary held **~90/10** (55 stable / 5 canary over 60
  requests). All `$0-GPU`.
- **−** One EPP per `InferencePool`: N models + a canary = N+1 EPPs (each ~200m cpu). Cheap with
  sims, but on a real multi-GPU fleet this is a per-pool cost to plan for.
- **+** One vendor-neutral gateway spans the core serving path (GIE) and the multi-tenant gateway (multi-provider).
- **−** agentgateway is young (v1.2.x) and CNCF-sandbox-tier; its OSS edition lacks virtual keys.
- **−** `InferenceObjective` is still alpha; schema may shift; we pin GIE v1.5.0 and verify the
  served schema (see runbook).
- The classic `LLMInferenceService`/KServe three-way comparison ([ADR-0006](/decisions/0006-raw-vllm-vs-kserve), pending) is unaffected;
  GIE is the routing layer, KServe is the serving-lifecycle layer.

## References

- Runbook `inference-gateway.md`. GIE v1.5.0; agentgateway v1.2.1;
  `llm-d-inference-sim` v0.8.2. Supersedes the original ADR-005 framing (now resolved here).
