---
title: "ADR-0034: Tenant-edge guardrails (PII masking and prompt-injection block)"
---

## Status

Accepted (2026-06-25). Optional capability, **off by default** (`features.guardrails: false`). Depends on
[ADR-0013](/decisions/0013-gateway-layering) (LiteLLM as the tenant edge above the inference gateway),
[ADR-0031](/decisions/0031-config-driven-feature-selection) (config-driven feature selection),
[ADR-0027](/decisions/0027-deployment-profiles) (the LiteLLM release lives in the `llm-gateway` layer).

## Context

The platform governs the tenant edge for identity and economics already: LiteLLM issues virtual keys,
meters spend, and enforces per-key budgets ([ADR-0013](/decisions/0013-gateway-layering)). It does **not**
inspect prompt or response **content**. For a multi-tenant inference edge that is a visible gap: a
tenant can send personal data that reaches a model and downstream logs unmasked, or send an override
prompt ("ignore previous instructions") with no platform-level refusal. The security column of an
inference platform is policy plus authentication plus **guards**; this stack had the first two
([ADR-0029](/decisions/0029-security-enforcement), [ADR-0026](/decisions/0026-auth-sso)) and not the third.

Scope for the first increment is two guards that are cheap, self-contained, and demonstrable:

- **A) PII masking** of the request before it leaves the proxy.
- **B) Prompt-injection / jailbreak blocking** of override prompts.

Toxicity moderation and an external safety model (Llama Guard, Lakera) are deliberately out of scope
for v1 (they imply a model dependency or an external API key, neither of which fits a self-contained
lab).

Two placement options were considered:

1. **Guardrails in the agentgateway data plane** (an `ext_proc` content-inspection service on the
   GIE/agentgateway path, [ADR-0005](/decisions/0005-inference-aware-routing)). Rejected for v1. agentgateway
   routes on headers, model name, and CEL over the body; it is not a content-safety engine, so this
   means building and wiring a new external processor. It is also not tenant-aware: guardrail policy
   is naturally per-key and per-team, and only LiteLLM holds that identity.
2. **Guardrails at the LiteLLM tenant edge.** Chosen. LiteLLM is already in the request path for every
   tenant call, understands the OpenAI `/v1` schema and streaming, and ships the integrations as
   configuration: a `presidio` guardrail for PII and the built-in `litellm_content_filter` guardrail
   for injection. No new external dependency, no API key, no GPU.

This keeps a clean split: **LiteLLM owns tenant-edge concerns** (identity, budget, guards),
**GIE/agentgateway owns inference-aware routing** (placement). The data plane stays lean.

## Decision

Add an **optional, off-by-default capability group** (`guardrails`, [ADR-0031](/decisions/0031-config-driven-feature-selection))
in the `llm-gateway` layer that ships two always-on guards on the LiteLLM edge:

- **A) `presidio-pii-mask`** (`guardrail: presidio`, `mode: pre_call`, `default_on: true`). The PII
  entities in `pii_entities_config` (email, phone, credit card, US SSN, IBAN, person) are masked in
  the request before it is sent upstream. Backed by self-hosted **Presidio analyzer + anonymizer**
  (`platform/guardrails/`, namespace `guardrails`, images digest-pinned to `2.2.361`). MASK is
  fail-open on analyzer error; a `BLOCK` entity would be fail-closed.
- **B) `prompt-injection-block`** (`guardrail: litellm_content_filter`, `mode: pre_call`,
  `default_on: true`). The built-in content filter blocks on the `prompt_injection_jailbreak`,
  `prompt_injection_system_prompt`, and `prompt_injection_data_exfiltration` categories. A match
  raises **HTTP 400** before any model is called, so the block needs no GPU. This guard is
  engine-internal to LiteLLM and deploys no extra pod.

**Wiring is approach (a): inject only when on.** A new resolver `scripts/resolve-guardrails.sh` (chained
from `make resolve-groups`) renders `clusters/ai-dev/litellm-guardrails.generated.yaml`, a third Helm
values file on the LiteLLM release. When the feature is on it carries the `proxy_config.guardrails`
block; when off it is an empty no-op, so the base `platform/litellm/values.yaml` never references the
Presidio services and the LiteLLM config has no inert guardrail. Disabling the feature cascades a clean
delete of both the Presidio group and the LiteLLM config. Proven on bring-up by `make guardrails-smoke`
(`scripts/smoke-guardrails.sh`): injection returns 400, Presidio recognizes the PII LiteLLM masks.

**Scope split:** the **guards as a governed plane** (PII masking + injection block at the tenant edge)
are platform substrate; the **specific entity list and injection categories** are examples, tuned per
fork. The value claim is the guard plane, not any particular pattern set.

## Consequences

- + Completes the security column: policy ([ADR-0029](/decisions/0029-security-enforcement)) plus authentication
  ([ADR-0026](/decisions/0026-auth-sso)) plus **content guards**, all at the edge that already holds tenant
  identity.
- + Self-contained: no external SaaS, no API key, no GPU. Presidio runs on CPU; the injection guard is
  pure configuration. Consistent with the declarative, offline-capable posture.
- + Off-by-default plus the inject-only-when-on resolver means zero blast radius on the critical path;
  a fork opts in with one `config.yaml` flag.
- − The injection guard is **keyword/heuristic**, not model-based. It blocks the common override and
  jailbreak phrasings (validated by the smoke test) but is not a complete defense. A model-based
  upgrade (Meta Prompt-Guard on vLLM, or an external service such as Lakera) is the documented next
  step if higher fidelity is required.
- − Heuristic matching can over-block legitimate prompts that combine an instruction verb with a
  blocked phrase. The feature is opt-in, so a fork accepts that trade explicitly; entity list and
  categories are tunable in the generated overlay's source resolver.
- − If a guard must cover ingress that **bypasses LiteLLM** (the MCP tool plane,
  [ADR-0033](/decisions/0033-mcp-gateway-profile), or any direct data-plane access), the right home is an
  agentgateway `ext_proc` processor, not LiteLLM. That is the trigger to revisit option 1; it is not
  needed while LiteLLM is the sole tenant ingress.
- − Presidio analyzer loads a spaCy model, so first-Ready is slow and memory (not CPU) is the binding
  resource (request 1Gi, limit 2Gi). Read-only rootfs requires the temp/cache redirect onto `/tmp`.

Relates to [ADR-0013](/decisions/0013-gateway-layering) (LiteLLM tenant edge, the plane these guards attach to),
[ADR-0029](/decisions/0029-security-enforcement) (governance scope-split framing),
[ADR-0026](/decisions/0026-auth-sso) (the authentication guard already present),
[ADR-0031](/decisions/0031-config-driven-feature-selection) (opt-in capability selection),
[ADR-0033](/decisions/0033-mcp-gateway-profile) (the parallel tool plane a future data-plane guard would cover).
