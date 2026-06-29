---
title: "ADR-0013: Gateway layering, LiteLLM above GIE not instead of it"
---

**Status:** Accepted
**Date:** 2026-06-20
**Amended:** 2026-06-22. External commercial providers route through agentgateway as a unified, governed
egress (was: attached directly at LiteLLM). See *Amendment* below.

## Context

The stack already routes inference through **Gateway API + the Gateway API Inference Extension
(GIE)** on **agentgateway**: an `InferencePool` + Endpoint Picker does inference-aware,
model-aware routing (KV-cache/queue-depth endpoint selection, model/canary splits). What it does
*not* do is the tenant-facing **economics** layer: virtual API keys, per-key spend budgets, TPM/RPM
rate limits, a spend ledger, and a single OpenAI `/v1` facade across local + commercial providers.
That is the tenant gateway jump to a self-hosted LLM platform. We need to decide how that layer relates to GIE.

## Decision

**Add LiteLLM as a control-plane layer *above* the existing GIE data plane, not as a replacement.**

- **GIE / agentgateway = data plane.** Inference-aware routing to model-server endpoints. Stays.
- **LiteLLM = control plane / economics.** Virtual keys, budgets, TPM/RPM, spend, `/v1` facade,
  multi-provider. New.

Request path: `client → LiteLLM /v1 (key auth, budget check, spend log) → inference-gateway
(model-aware) → InferencePool/EPP → vLLM`. LiteLLM's local model targets the in-cluster gateway
(`http://inference-gateway.inference.svc/v1`). External commercial providers route through the same
gateway (see *Amendment (2026-06-22)*).

This matches upstream guidance: the GIE docs explicitly position self-hosted models as something to
"integrate alongside MaaS providers in higher-level AI Gateways like LiteLLM", i.e. the two are
**different, complementary layers**.

LiteLLM runs from the official Helm chart (`ghcr.io/berriai/litellm-helm`, pinned `1.89.2`), backed
by **CloudNativePG** Postgres (single instance; `allow_requests_on_db_unavailable=true` mitigates
the SPOF), no Redis (single replica). Master/salt/DB/upstream secrets come via ESO (ADR-0011); the
salt key is write-once. Schema migration runs as the chart's Argo PreSync-hook Job with the proxy's
`DISABLE_SCHEMA_UPDATE=true`.

## Amendment (2026-06-22): agentgateway is the unified external egress

The original decision left external commercial APIs (OpenAI, Anthropic, …) attached **directly at
LiteLLM**. We now route them through **agentgateway** instead, so *all* model traffic, local and
external, exits through one governed data plane:

`client → LiteLLM /v1 (keys, budgets, spend) → agentgateway → {GIE/InferencePool/EPP → vLLM | OpenAI |
Anthropic | Gemini | Bedrock}`

LiteLLM points at **one** upstream (agentgateway); agentgateway normalizes every provider to an
OpenAI-compatible response (its **AIProvider** schema-translation orchestrator, first-class OpenAI/
Anthropic/Gemini/Bedrock + any OpenAI-compatible) and returns token `usage`, so LiteLLM still computes
spend (usage × its pricing table) and enforces budgets unchanged.

**agentgateway plays two distinct roles, keep them honest:**

- **Inference-aware router** for self-hosted vLLM (GIE `InferencePool`/EPP, KV/queue-aware). Local only.
- **Normalizing egress proxy** for external SaaS (the AIProvider path). GIE does **not** apply to SaaS
  (no KV/queue to observe); do not claim "ChatGPT routed by GIE."

**Why:** one egress chokepoint yields a single NetworkPolicy egress rule, one OpenTelemetry trace surface,
and one auth/RBAC/guardrail point across local + external alike. For a platform whose differentiator is
governance over a shared substrate, "everything exits through the AI gateway" is the cleaner posture; it
also collapses LiteLLM config to a single backend and places upstream provider keys in the data plane
that makes the call.

**Fallback:** agentgateway has first-class support for the big-4 + any OpenAI-compatible API. For a
long-tail provider it does not natively normalize, keep **LiteLLM-direct** for *that* provider only
(LiteLLM supports 100+). Big-4 + OpenAI-compatible route through agentgateway.

**Verify before relying on it:** confirm `usage` round-trips through agentgateway for one external
provider so LiteLLM's spend/budget math binds (one short spike).

**Layering is unchanged:** LiteLLM stays the client-facing economics layer on top; only its *external*
backend moves from the provider URL to agentgateway. This refines, but does not reverse, the rejection of
"LiteLLM as the only gateway" below (GIE stays the local data plane).

## Alternatives considered

- **Envoy AI Gateway** (consolidate economics into the data plane). Rejected for now: pre-GA (1.0
  target ~2026-06-30), Redis-required, and **token-quota only, with no virtual keys, no $budgets, no
  spend ledger**. It can't deliver the tenant gateway. Revisit post-GA *only* to potentially
  consolidate the data plane; it does not replace LiteLLM's economics.
- **GIE alone** (push budgets/keys into routing). Rejected: GIE is deliberately a routing layer;
  it has no key/budget/spend model. Wrong layer for tenant economics.
- **LiteLLM as the only gateway** (drop GIE, point LiteLLM straight at vLLM). Rejected: throws away
  the inference-aware routing that is the platform's depth differentiator. Keep both layers.

## Consequences

- Two layers to operate, but each does one job (economics vs inference-aware routing): clean
  separation, and each is independently swappable (Envoy AI GW could replace the data plane later;
  a different economics layer could replace LiteLLM).
- Adds an always-on Postgres + proxy on the CPU node pool (small, non-GPU cost): the self-hosted LLM
  platform edge is meant to be always available; the GPU model underneath stays scale-to-zero.
- Tenant→key→budget data lives in Postgres (tenant data, not git). SSO/audit (LiteLLM Enterprise)
  are out of scope; unification with OIDC is part of multi-tenancy/governance (see SSO/auth).
- Sources: GIE↔LiteLLM layering (GIE docs); Envoy AI Gateway maturity/feature gaps; LiteLLM
  vkeys/budgets/spend.
