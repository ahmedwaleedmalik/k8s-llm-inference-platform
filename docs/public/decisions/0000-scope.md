---
title: "ADR-0000: Scope, bar, and non-goals"
---

**Status:** Accepted
**Date:** 2026-06-23

## Context

This is the foundational ADR. Every other decision in this set assumes the scope fixed here. Without
it, a reader cannot tell whether a gap (no TLS-everywhere, a single GPU, a 0.5B model) is an oversight
or a deliberate boundary, and an ADR set that opens ambiguous reads as either overclaiming or
unfinished. Both are worse than a stated, narrow scope.

The tension this ADR resolves: the **design target** is a production-grade, HA, multi-tenant
LLM-as-a-Service platform; the **default running deployment** is a deliberately minimized single-GPU,
scale-to-zero, 0.5B-model lab at ~$30-35/mo. Those are not in conflict, but only if the relationship
is written down. The cheap lab is the *default cost-optimized footprint*; the HA/multi-GPU path is
validated separately on a multi-GPU substrate (Vast), not *what the platform reduces to*.

## Decision

### What this is

A **forkable, GitOps-managed reference stack for running and operating OpenAI-compatible LLM inference
on Kubernetes**, GKE-first. Every operational concern (GPU scheduling, inference-aware routing, tenant
gateway economics, secrets, model delivery, observability, autoscaling) is an explicit, forkable
decision recorded as an ADR and expressed as plain manifests, not a managed black box.

The architecture is designed for HA/enterprise from the start and built incrementally: serving →
inference-aware routing → tenant gateway economics → experience layer. It **integrates** open-source
components (vLLM, KServe, Gateway API Inference Extension, Kueue, LiteLLM, agentgateway, KEDA,
Prometheus/Grafana, External Secrets); it does not reinvent them.

### What it is NOT

- **Not a managed product or a multi-tenant PaaS-for-infra.** Tenants consume an OpenAI `/v1` endpoint
  with a virtual key; they do not get a namespace to deploy their own workloads into.
- **Not yet a cloud-agnostic *production* platform.** Portability is proven by running the same
  manifests on a second substrate, not by a production SLA on each.
- **TLS-everywhere and full multi-team RBAC/chargeback are not all shipped today.** SSO (Dex +
  oauth2-proxy), policy enforcement (Kyverno + default-deny NetworkPolicy), tenant-edge guardrails
  (PII + prompt-injection), and OpenCost cost attribution **are** shipped; in-cluster mTLS, multi-team
  RBAC/SCIM/audit, and per-namespace chargeback remain designed-for and tracked (see the
  security-posture doc and the hardening ADRs).
- **Single-L4 is the cost-optimized default, not the ceiling.** Multi-GPU is validated on a multi-GPU
  substrate (Vast): a 2-replica zero-downtime RollingUpdate overlay with EPP fan-out across N
  endpoints, plus time-slicing tested for GPU sharing. The published per-GPU benchmarks are still
  single-L4 (`benchmarks.md` needs the multi-GPU/time-slicing numbers added). "Returns 200 on a small
  model" is not a throughput claim, and this set never makes one.

### The bar

The metric that matters is a **working end-to-end slice a forker can adopt**, not the count of layers
authored. The bar is the core path actually working: a forker clones this, points an IDE at it, and
gets chat + FIM + agentic coding behind virtual-key budgets, on a real coder model, with the decisions
and benchmarks written down. Breadth beyond that is deferred until the core slice is proven and shipped.

### The two framings, held together

- **North star (product):** judge every capability against the production target: warm multi-node GPU
  pools, large models, many tenants, no forced scale-to-zero, TLS/SSO/chargeback. Never *design out* a
  production capability because a lab artifact makes it look unnecessary (e.g. "scale-to-zero deletes
  the node, so a node-warm cache is pointless", wrong for a real warm pool; it is a lab *validation
  caveat*, not a product verdict).
- **Counterweight (discipline):** the north star alone makes nothing cuttable. So: before authoring a
  new capability, prove and ship the slice already in hand. Remaining gaps (in-cluster mTLS,
  multi-team RBAC, large-model multi-node fan-out) are *deferred-and-tracked*, never *designed-out*;
  HA multi-replica and multi-GPU are validated on the Vast substrate.

## Consequences

- Every other ADR may assume this scope and need not re-litigate "but is this production-ready?": the
  answer is recorded here: the *architecture* targets production; the *default deployment* is a cheap
  lab; the HA/multi-GPU path is validated on a separate substrate; gaps are tracked, not hidden.
- A deliberate default-off control (no alerting in the cheap footprint, no in-cluster mTLS) is
  documented as deliberate (see [ADR-0003](/decisions/0003-inference-slos) (SLO honesty),
  [ADR-0029](/decisions/0029-security-enforcement) (enforcement controls shipped, default-off until
  multi-tenant), and the public security-posture doc) so it is not mistaken for an oversight.
- Claims are bounded to what is proven: the publishable claim is a GKE-first reference stack for
  OpenAI-compatible inference on K8s with GitOps, GPU admission, observability, benchmarks, shipped
  governance (SSO/policy/guardrails/cost), multi-GPU HA validated on a second substrate, and
  routing/KServe/llm-d/coder paths; portable across clouds, not a cloud-agnostic production PaaS with a
  per-cloud SLA.
- New capabilities are gated by the bar above, not by the north star alone.

Relates to every ADR in this set; most directly [ADR-0003](/decisions/0003-inference-slos) (SLOs are baseline-only), [ADR-0006](/decisions/0006-raw-vllm-vs-kserve) (lab vs
scale serving choices), [ADR-0029](/decisions/0029-security-enforcement) (product-grade hardening, shipped default-off), and
[ADR-0027](/decisions/0027-deployment-profiles)/[ADR-0031](/decisions/0031-config-driven-feature-selection) (deployment profiles + feature selection that make the small footprint
a configuration, not a constraint).
