---
title: "ADR-0033: Governed MCP gateway profile"
---

## Status

Accepted (2026-06-23). Optional capability, **off the critical path**. Depends on [ADR-0005](/decisions/0005-inference-aware-routing)
(agentgateway / Gateway API as the data plane), [ADR-0026](/decisions/0026-auth-sso) (Dex as the single OIDC issuer), [ADR-0031](/decisions/0031-config-driven-feature-selection)
(config-driven feature selection). Sibling to [ADR-0013](/decisions/0013-gateway-layering) (LiteLLM-above-GIE): this is the *parallel*
protocol plane, deliberately not routed through LiteLLM.

## Context

The agentic clients (Cline / opencode) want **tools**, not just completions. Tools speak the Model
Context Protocol (MCP), which is a **separate protocol plane** from the OpenAI `/v1` chat/embeddings
API: `/v1` carries model inference; MCP carries `tools/list` + `tools/call`. An MCP server handed
straight to a client is ungoverned (no auth, no quota, no audit, no trace), the same gap [ADR-0029](/decisions/0029-security-enforcement)
closed for the LLM path, now on the tool path.

agentgateway is **MCP-native**: it federates/multiplexes MCP servers behind one endpoint and applies
JWT/OIDC, RBAC, rate-limit and OpenTelemetry to MCP routes, the same data plane already standing in
front of vLLM and external SaaS ([ADR-0005](/decisions/0005-inference-aware-routing), [ADR-0013](/decisions/0013-gateway-layering) amendment). So the governed tool plane is *free
substrate*, not a new component.

Two framings were possible and one is wrong:

1. **Route MCP through LiteLLM.** Rejected. LiteLLM is an OpenAI-`/v1` proxy (virtual keys, spend,
   model routing). MCP is not `/v1`: it has no model, no token usage to meter, no completion to
   normalize. Forcing MCP through LiteLLM would mean wrapping a non-LLM protocol in an LLM proxy for
   no governance gain. The governance MCP needs (authn, rate-limit, trace) is exactly what
   agentgateway already does at the route level.
2. **Govern MCP at the gateway, clients consume it directly.** Chosen.

## Decision

Add an **optional, off-by-default capability group** (`mcp-gateway`, [ADR-0031](/decisions/0031-config-driven-feature-selection)) that:

- Deploys **one safe, read-only example MCP server** (`@modelcontextprotocol/server-everything`,
  streamableHttp) in a dedicated `mcp-gateway` namespace. Its tools (echo/add/time/sampling) touch no
  filesystem and make no outbound calls, a sandboxed demo. It is the server agentgateway's own MCP
  tutorial uses, so the wiring is grounded, not invented.
- Exposes it through an `AgentgatewayBackend` (MCP target by label → supports federating more servers
  later) on an `HTTPRoute` that attaches cross-namespace to the **same shared `inference-gateway`** as
  the LLM paths: one governed data plane, no second gateway.
- Governs that route with: **auth** (`AgentgatewayPolicy.jwtAuthentication`, Strict, JWKS from Dex
  in-cluster, [ADR-0026](/decisions/0026-auth-sso)), **rate-limit** (`AgentgatewayPolicy.rateLimit.local`), and **trace**
  (agentgateway agent-wide OpenTelemetry config on the chart, gateway-level, not per-route).
- Is consumed by the **agentic clients directly**: `agent client → agentgateway MCP → MCP server`.
  LiteLLM is not in this path.

**Scope split ([ADR-0029](/decisions/0029-security-enforcement) product-grade framing):** the **governed MCP gateway**
(auth / policy / limit / trace over tool access) = **platform substrate, keep**; the MCP
**servers/tools** = **examples, swappable, not core**. The value claim is the policy plane over tools,
not any particular tool.

## Consequences

- + Strengthens the "AI gateway" claim beyond LLM routing: one governed plane for **both** model
  traffic (`/v1`) and tool traffic (MCP), vs a stack that only governs inference (Red Hat compare).
- + Adding a second safe server (fetch/filesystem/time) = one `targets:` entry; clients still see one
  endpoint. The substrate scales without re-plumbing.
- + Off-by-default + manual-sync → zero blast radius on the critical path; a fork opts in with one
  `config.yaml` flag.
- − Tracing needs an **OTLP backend that the lab does not yet ship** (obs is metrics-only,
  kube-prometheus-stack). Auth + rate-limit work without it; tracing is documented as a prerequisite.
- − The `jwtAuthentication.providers` shape + the cross-namespace JWKS `backendRef` are hand-authored
  from the agentgateway v1.2.x MCP-auth docs and need **live validation against v1.2.1**, the same
  caveat as the `portal-forward-auth` extAuth policy ([ADR-0026](/decisions/0026-auth-sso)).
- − `npx`-based server pulls its package on first boot; if the [ADR-0029](/decisions/0029-security-enforcement) default-deny NetworkPolicy
  group is also on, this namespace needs an npm-registry egress allowance (or a pre-baked image).

Relates to [ADR-0005](/decisions/0005-inference-aware-routing) (agentgateway data plane), [ADR-0013](/decisions/0013-gateway-layering) (LiteLLM `/v1` plane, the parallel one),
[ADR-0026](/decisions/0026-auth-sso) (Dex OIDC issuer / JWKS), [ADR-0029](/decisions/0029-security-enforcement) (governance scope-split framing, NetworkPolicy note),
[ADR-0031](/decisions/0031-config-driven-feature-selection) (opt-in capability selection).
