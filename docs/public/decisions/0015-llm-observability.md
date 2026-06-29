---
title: "ADR-0015: LLM observability, spend dashboard from Postgres now, Langfuse tracing deferred"
---

**Status:** Accepted
**Date:** 2026-06-20

## Context

LiteLLM ([ADR-0013](/decisions/0013-gateway-layering)) is the tenant economics layer (virtual keys / budgets / spend). The tenant gateway requires
**LLM-level observability** distinct from the infra metrics already in Prometheus/Grafana: (a) a
**spend/budget view** (per key/team/model cost + remaining budget), and (b) **prompt/token/cost
tracing** per request. We chose **Langfuse** (self-hosted) for tracing. Two facts force a split
decision rather than "deploy Langfuse and call it done":

1. **Langfuse v3 is heavy.** Self-hosted v3 requires Postgres **+ ClickHouse + Redis/Valkey + an
   S3-compatible blob store** (the official Helm chart's bundled subcharts are single-replica
   smoke-test only). Realistic footprint is ~8GB+ RAM, disproportionate for this ~$30-35/mo
   single-cluster lab and likely forces a larger/extra CPU node.
2. **LiteLLM's Prometheus metrics are Enterprise-gated.** LiteLLM moved its Prometheus integration
   (`litellm_spend_metric`, token/budget metrics) to Enterprise ($250/mo) in Sept 2024. The obvious
   "scrape LiteLLM `/metrics` into Grafana" path is **not available** to an OSS reference platform.

But LiteLLM already **writes spend to its own Postgres for free** (the `LiteLLM_SpendLogs` and
`LiteLLM_VerificationToken` tables, which is what makes budgets enforce, verified by the raw-vLLM GPU proof). That data is
sufficient for the spend/budget view.

## Decision

**Split the observability work: ship the spend dashboard now from Postgres; defer Langfuse tracing.**

- **Spend dashboard (now).** A Grafana dashboard backed by a **Postgres datasource** reading
  LiteLLM's spend tables in the existing CNPG `litellm-pg`. Access via a dedicated **least-privilege
  read-only role** (`grafana_ro`, CNPG managed role with the PG-builtin `pg_read_all_data`); its
  password flows GSM → ESO. The datasource is delivered as an **ESO-rendered Secret** labelled
  `grafana_datasource` (keeps the password out of git) and imported by the Grafana datasource
  sidecar. Reuses Grafana + CNPG; **no new infrastructure**. Panels: spend over time, spend by
  model, spend by key, tokens, remaining budget per key.
- **Langfuse tracing (deferred).** Langfuse stays the chosen tracing tool but lands
  as its own task when its v3 footprint is justified/affordable (reuse CNPG for its Postgres; bring
  ClickHouse + Redis + MinIO). LiteLLM → Langfuse is a one-line `success_callback: ["langfuse"]` when
  we get there.
  - **2026-06-20:** Langfuse tracing deferred on lab-footprint grounds only (not product value). PRODUCT TRIGGER = multi-tenant request tracing needed OR budget allows the v3 ClickHouse+Redis+MinIO footprint.

## Alternatives considered

- **LiteLLM `/metrics` → Prometheus → Grafana.** Rejected: Enterprise-gated; unusable for an OSS
  reference. (The free 3-month migration license is temporary and not forkable, wrong for a
  reference platform.)
- **Deploy full Langfuse v3 now for both tracing and spend.** Rejected for now: footprint
  disproportionate to the lab; the spend view (the higher-value, user-visible economics signal) is
  achievable at near-zero cost without it.
- **Langfuse v2 (Postgres-only, lighter).** Rejected: v2 is EOL/unmaintained and missing v3
  features, wrong signal for a platform meant to reflect SOTA.
- **Reuse the LiteLLM app DB user for Grafana.** Rejected: over-privileged (read-write) for a
  dashboard; a dedicated read-only role is the least-privilege choice.

## Consequences

- **+** The tenant gateway economics story is observable (keys/budgets/**spend**) with no added infra cost, reusing
  Grafana + CNPG.
- **+** Strict least-privilege: Grafana can only `SELECT` (via `pg_read_all_data`); it can never
  mutate LiteLLM data. Password never in git (GSM → ESO).
- **−** No request-level prompt/token tracing yet (that is Langfuse tracing).
- **−** The dashboard SQL is coupled to LiteLLM's table/column names (`"LiteLLM_SpendLogs"`,
  `"LiteLLM_VerificationToken"`); a LiteLLM schema change could require dashboard SQL updates.
- **−** Single Postgres instance → the datasource targets `litellm-pg-rw` (the `-ro` service has no
  endpoints without replicas); switch to `-ro` when HA lands (later multi-tenancy/HA hardening).
- The dashboard and datasource live in the `llm-gateway` deployment layer (`grafana-litellm` app,
  `dashboards/litellm/`) so the base `platform` profile does not require LiteLLM secrets.
- New secret: GSM `litellm-grafana-ro-password` (secrets-inventory).

## References

- Langfuse v3 self-hosting (Postgres + ClickHouse + Redis + S3): langfuse.com/self-hosting.
- LiteLLM Prometheus → Enterprise (Sept 2024): BerriAI/litellm discussion #5163; LiteLLM pricing.
- LiteLLM spend logging to Postgres (OSS) + Langfuse `success_callback`: docs.litellm.ai.
- [ADR-0013](/decisions/0013-gateway-layering) (LiteLLM), [ADR-0011](/decisions/0011-secrets-and-config-strategy) (secrets/ESO).
