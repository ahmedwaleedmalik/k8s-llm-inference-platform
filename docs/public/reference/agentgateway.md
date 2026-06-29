---
title: "agentgateway egress and MCP"
---

What the agentgateway data plane actually does today, stated precisely, because two of its behaviors are
easy to overclaim: the external-provider **egress** path (implemented) and the **warm fallback** to an
alternative gateway (documented, not built). This page separates them so the difference is explicit.

> Operating the gateway: [Inference gateway](/guides/inference-gateway).

## Egress to external providers like Anthropic, OpenAI etc

All model traffic, local and external, exits through one governed data plane.
External commercial APIs are not attached at LiteLLM; they route through agentgateway in its
**normalizing-egress** role.

This path is feature-gated (`features.egress`, default off): the `egress` group carries an
`anthropic-api-key` ExternalSecret that needs a real provider key, so a default fork stays clean and
needs no Anthropic account. Enable it with `features.egress: true` (then `make resolve-groups`) once
the key is in the secret backend; the `claude-haiku` LiteLLM alias only routes when it is on.

What is actually deployed when enabled: one `AgentgatewayBackend` for Anthropic (`claude-haiku-4-5`)
plus an `HTTPRoute` that matches it by `X-Gateway-Base-Model-Name`
(`routing/gateway-api-inference/egress/`). On that path agentgateway takes an OpenAI
`/v1/chat/completions` request, translates it to the Anthropic `/v1/messages` shape, and normalizes the
reply back to OpenAI form **including a `usage` object**, so LiteLLM keeps metering spend (usage x its
pricing table). The upstream provider key lives in the data plane (synced by External Secrets); LiteLLM
never holds it.

Two roles, kept honest:

- **Inference-aware router** for self-hosted vLLM (GIE `InferencePool` / EPP, KV-cache and queue aware).
  Local only.
- **Normalizing-egress proxy** for external SaaS (the AIProvider path). External SaaS has no KV-cache or
  queue to observe, so it deliberately does **not** go through an `InferencePool`. GIE routing does not
  apply to a SaaS endpoint, and the platform does not claim otherwise.

Scope of what ships: **one** provider backend (Anthropic) as the worked example. Adding OpenAI, Gemini,
or Bedrock is another `AgentgatewayBackend` of the same shape, not new machinery. It is an extensible
pattern with one concrete instance, not a multi-provider catalog.

## MCP gateway

The governed MCP tool plane is an optional, off-by-default capability group. The split is
deliberate: the **gateway** (auth, rate-limit, trace over tool access) is platform substrate; the **MCP
server** behind it is a swappable example, not a core deliverable.

| Control | State | Detail |
|---|---|---|
| Example MCP server | Implemented (example) | `@modelcontextprotocol/server-everything`, read-only tools (echo / add / time / sampling), no filesystem or outbound calls. Swappable by design. |
| Routing through the shared gateway | Implemented | `AgentgatewayBackend` (MCP target by label) on an `HTTPRoute` attached cross-namespace to the same `inference-gateway`. One data plane, no second gateway. |
| Auth (JWT / OIDC) | Implemented | `AgentgatewayPolicy.jwtAuthentication`, Strict mode, JWKS fetched from in-cluster Dex. |
| Rate limit | Implemented | `AgentgatewayPolicy.rateLimit.local`, 5 req/s burst 10. A local in-proxy limiter; a multi-replica gateway would graduate to a shared limiter. |
| Tracing | Partial | The OpenTelemetry hook is agent-wide config on the chart, but the observability stack is metrics-only with no traces backend shipped. Until an OTLP collector or Tempo is added, tracing is a no-op; auth and rate-limit work without it. |
| Field-shape validation | Pending | The `jwtAuthentication.providers` shape and the cross-namespace JWKS `backendRef` are hand-authored from the agentgateway v1.2.x docs and need live validation against v1.2.1. |

## Warm fallback (documented, not implemented)

This needs the plainest possible statement: **there is no warm fallback in the deployment.** It is a
design note, not a runtime feature.

The reasoning is sound and recorded: the standard agentgateway implements (Gateway API Inference
Extension) is GA, so the data plane is swappable in principle. The note recommends keeping Envoy Gateway,
kgateway, or GKE Gateway as a **documented escape hatch** so a fork is never locked into a single
implementation (see the [roadmap](/reference/roadmap) entry).

What is **not** present today:

- No alternative gateway is deployed. The repo ships agentgateway only; there are zero Envoy Gateway,
  kgateway, or GKE Gateway manifests.
- There is no dual-path, no automated failover, and no health-triggered switchover. "Warm" overstates it:
  nothing is kept warm.
- There is no migration runbook for switching data planes.

The honest description is: the routing layer targets a GA, portable standard, so swapping the proxy is
*feasible*; the fallback itself is unbuilt. It is a deferred item with a trigger (before depending on
agentgateway in a production posture), not a control in place.

## The principle

The egress path and the MCP gateway are real and exercised; their limits (one example provider, one
example MCP server, tracing pending a backend, JWT shape pending live validation) are stated rather than
glossed. The warm fallback is a portability claim about the standard, not a feature of the deployment, and
is labeled as such. Treating "the standard is swappable" as if it were "a fallback is wired" would be the
overclaim this page exists to prevent.
