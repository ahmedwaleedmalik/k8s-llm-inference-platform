---
title: "Security posture"
---

What this platform enforces today, and what it deliberately does not, yet. The gaps below are
**design decisions for a single-tenant reference deployment, not oversights**: each maps to a tracked
hardening item with a stated trigger for turning it on. The architecture targets a production-grade,
multi-tenant deployment; the default footprint is a cheap single-tenant lab, and the security surface is
sized to that, on purpose.

> Operating guide for the enforcement controls: [Security enforcement](/guides/security-enforcement).
> The assumption these gaps depend on: [Trust model](/reference/trust-model).

## What IS enforced

**Secrets never live in git or in OpenTofu state.** Every secret is a *name*, materialized at runtime by
External Secrets Operator from GCP Secret Manager. On GKE, ESO authenticates keylessly via
Workload Identity, with no static service-account key. A forker seeds secret *values* once into Secret
Manager (see the [secret contract](/guides/secret-contract)); the repo holds only references.

**Model endpoints require auth.** raw-vLLM enforces an API key (`VLLM_API_KEY`) on every `/v1/*` request.
Tenants do not call model servers directly; they call LiteLLM with a **virtual key**, and LiteLLM
presents the shared upstream key to the serving layer. Virtual keys carry per-key/team budgets, TPM/RPM
limits, and a spend ledger: the tenancy and economic boundary is the LiteLLM layer.

**TLS at the public edge.** When a domain is configured, the agentgateway edge terminates Let's Encrypt
TLS (cert-manager) and owns the stable HTTPS issuer URL SSO depends on. In-cluster backends
stay plain HTTP behind that edge today; see "deliberately deferred" below.

**SSO is shared identity, not shared authorization.** Dex is the issuer for Argo CD, Grafana, Open
WebUI, LiteLLM admin UI, and oauth2-proxy forward-auth surfaces. Each application still owns its role
mapping: Argo CD and Grafana map `admin@<domain>` to admin, LiteLLM maps `PROXY_ADMIN_ID`, and the key
portal lets any signed-in user manage only keys scoped to that user's email. n8n is SSO-gated at the
edge but keeps its OSS owner login behind that gate.

**Optional, off-by-default enforcement (the `security` group):** when multi-tenancy warrants it, two
*logical* controls become *enforced* ones:

- **SR1, NetworkPolicy** (native `networking.k8s.io/v1`, CNI-portable): default-deny + allow-list so
  LiteLLM is the *sole* authorized caller of the model servers and GIE gateway. Removes the
  network-bypass around virtual keys and budgets. Needs a NetworkPolicy-enforcing dataplane (on GKE,
  Dataplane-V2, set at cluster creation).
- **SR2, Kyverno admission**: rejects any pod requesting `nvidia.com/gpu` in a managed namespace that
  lacks the Kueue queue-name label, so a pod cannot bypass GPU quota/fair-share.

These ship **dormant**: a single-tenant deployment never hits the gaps they close, so they are enabled by
a config flag when a second team or GPU flavor arrives, not carried as always-on complexity.

## What is DELIBERATELY deferred

Each item below is decided and tracked, with the trigger that pulls it forward. None is an accident.

| Not enforced today | Why deferred | Enabled when |
|---|---|---|
| **TLS everywhere (backend / mTLS)** | The public edge terminates TLS; in-cluster hops stay HTTP. A single trusted-tenant lab gains little from intra-cluster mTLS, and it adds a cert-rotation surface. | Untrusted in-cluster workloads, or a compliance requirement for encryption-in-transit between pods. |
| **Full RBAC / tenant isolation** | The tenancy boundary is LiteLLM (virtual keys/budgets), not the K8s namespace; tenants consume a `/v1` endpoint, not a namespace. Per-tenant `namespace` + `ResourceQuota` + RBAC + NetworkPolicy is the baseline, but multi-team RBAC, SCIM, and audit are not wired. | More than one team shares the cluster; the multi-tenancy/governance milestone (home SSO + a self-service key portal). |
| **Rate limiting at the gateway** | LiteLLM enforces per-key TPM/RPM and budgets (the economic limit). A separate edge rate-limit (e.g. agentgateway/MCP) is not configured. | A public-facing or MCP-exposed surface needs abuse protection independent of per-key budgets. |
| **Fail-closed budgets (SR3)** | The lab runs `allow_requests_on_db_unavailable: true` (availability-first): if Postgres is down, requests pass un-metered. Fail-closed is a profile knob requiring CloudNativePG HA (`instances ≥ 3`) + a Redis-backed budget/rate cache. | The `prod` profile, where overspend risk outweighs availability; rides the HA hardening work. |
| **SLO breach alerting** | SLOs are recorded and dashboarded but Alertmanager is disabled; the SLOs are baseline-only (one model, one GPU). | First multi-replica/multi-model serving ⇒ per-model SLOs + alerting. |

## The principle

The platform's controls exist *logically* from the start (virtual keys, budgets, GPU quota, secret
externalization) and become *enforced* as the deployment grows from a single-tenant lab toward a
multi-tenant platform. The footprint is a configuration, not a constraint: enabling a control is flipping
a flag and seeding a dependency, not rearchitecting. A narrow-but-stated posture is the honest position
for a reference deployment; the [roadmap](/reference/roadmap) records the doors left open on purpose.
