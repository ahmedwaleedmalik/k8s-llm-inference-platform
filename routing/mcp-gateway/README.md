# Governed MCP gateway (ADR-0033)

Exposes **one safe example MCP server** through the shared agentgateway data plane, with **auth +
rate-limit + tracing**, consumed by the **agentic clients** (Cline / opencode), **not by LiteLLM**.

MCP is a **parallel protocol plane** to the OpenAI `/v1` LLM path:

```
agent client ──(MCP /mcp)──> agentgateway ──> MCP server   (this profile)
LiteLLM      ──(/v1)───────> agentgateway ──> {vLLM | SaaS} (ADR-0013, separate plane)
```

The MCP **server** is a swappable example; the **governed gateway** in front of it is the platform
substrate (scope split, see ADR-0033).

## Opt-in (off by default, off the critical path)

```yaml
# environments/ai-dev/config.yaml
features:
  mcp-gateway: true
```

Then `make resolve-groups && make root`. The Argo Application is **manual-sync**: enabling it *creates*
the app; sync it once routing-core (the shared `inference-gateway`) and identity (Dex) are up.

## What gets deployed (`routing/mcp-gateway/`)

| File | Resource | Purpose |
|------|----------|---------|
| `mcp-server-everything.yaml` | Deployment + Service | example MCP server (read-only tools), streamableHttp :3001, `appProtocol: agentgateway.dev/mcp` |
| `backend.yaml` | `AgentgatewayBackend` | MCP backend; federates/multiplexes MCP targets by label |
| `httproute.yaml` | `HTTPRoute` | `/mcp` + OAuth discovery paths → backend; attaches cross-ns to `inference-gateway` |
| `policy-auth.yaml` | `AgentgatewayPolicy` + `ReferenceGrant` | JWT/OIDC (Dex) validation, Strict mode; JWKS from `dex:5556/keys` |
| `policy-ratelimit.yaml` | `AgentgatewayPolicy` | local rate-limit 5 req/s, burst 10 |

### Governance, applied (the point of the profile)

- **Auth**: `policy-auth.yaml` validates a Dex-minted bearer JWT (`iss=https://auth.<domain>`) before
  any tool call reaches the server. `mcp.resourceMetadata` advertises the OAuth resource server so MCP
  clients self-discover where to get a token. (agentgateway MCP-auth docs.)
- **Rate-limit**: `policy-ratelimit.yaml` caps tool-call volume per route so a runaway agent loop
  can't hammer the tool server. Local limiter (zero deps); graduate to global on a multi-replica
  gateway (same note as ADR-0029 SR3 Redis budget cache).
- **Tracing**: agentgateway emits OpenTelemetry traces. Tracing is **agent-wide config**, not a
  per-route policy: set it on the agentgateway chart (`routing-core` `agentgateway.yaml` values):

  ```yaml
  # routing/gateway-api-inference/agentgateway/values.yaml
  config:
    tracing:
      otlpEndpoint: http://<otel-collector>.<ns>.svc:4317
      randomSampling: true
  ```

  **Prerequisite:** the lab obs stack is metrics-only (kube-prometheus-stack); there is **no traces
  backend yet**. Add an OTLP collector / Tempo and point `otlpEndpoint` at it. Until then, auth +
  rate-limit work; tracing is a no-op.

## Agentic-client config snippet

The clients consume MCP **directly** at the gateway endpoint (replace `<domain>` and `<JWT>`).

Cline / opencode (streamable HTTP MCP server):

```json
{
  "mcpServers": {
    "platform-tools": {
      "url": "https://mcp.<domain>/mcp",
      "headers": { "Authorization": "Bearer <JWT-from-Dex>" }
    }
  }
}
```

Tier-0 (no domain): port-forward the gateway and point the client at `http://localhost:8080/mcp`
(auth still enforced; mint a token via the Dex device/password flow).

## Live-validate (when the stack is up)

1. **Routing**: MCP client connects to `/mcp`, `tools/list` returns the example server's tools.
2. **Auth**: request with no/invalid bearer → `401`; valid Dex JWT → tools reachable.
   `curl https://mcp.<domain>/.well-known/oauth-protected-resource/mcp` returns resource metadata.
3. **Rate-limit**: burst > 10 req/s on `/mcp` → `429`.
4. **Trace**: once an OTLP target exists, a tool call shows a span in the traces backend.
5. **Field shapes**: confirm `jwtAuthentication.providers` + the cross-ns JWKS `backendRef` against
   agentgateway **v1.2.1** (hand-authored from v1.2.x MCP-auth docs; same caveat as the
   `portal-forward-auth` extAuth policy).
