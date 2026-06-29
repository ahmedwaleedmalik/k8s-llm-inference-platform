---
title: "ADR-0026: Authentication and SSO with Dex and oauth2-proxy"
---

## Status

Accepted (2026-06-22). Supersedes the parked "Authentik vs Authelia vs Dex" sketch. Depends on a stable
HTTPS auth edge, [ADR-0011](/decisions/0011-secrets-and-config-strategy) (ESO secrets), and
[ADR-0013](/decisions/0013-gateway-layering) (LiteLLM tenant edge).

## Context

Multiple platform apps need login: ArgoCD, Grafana, the Open WebUI chat UI, *and* developers need a
self-serve LiteLLM virtual key. The constraints (the fork operator stated them): **config-as-code, no
clicking auth into a dashboard**; **generic** (each fork plugs in its own identity source); the operator
personally uses a **Google** account; **cheap/OSS, minimal components**. LiteLLM's turnkey auth (JWT,
JWT→key, UI self-serve, SSO>5 users) is **Enterprise-gated**, so auth must happen at the **edge** and a
thin portal mints keys against LiteLLM's free OSS `/key/*` API.

## Decision

**A single central OIDC issuer (Dex), every app federated to it, with a thin forward-auth + key-portal
for the LiteLLM path.** Not a heavyweight IdP: Dex is a lightweight broker whose entire config
(connectors, static clients, static users) is YAML, read-only at runtime, so the platform stays pure config-as-code.

- **Dex (Track 2)** = the one issuer at `https://auth.<domain>`. **Default = a static admin user whose
  password/hash `make seed-secrets` stores in the secret backend**, so a fresh clone has working auth
  with **zero external IdP setup**. **Federation is opt-in**: uncomment
  the `google` connector (or github/oidc/ldap/saml) + add creds via ESO, a one-block, config-as-code
  swap; Dex makes "bring your own SSO" trivial. Per-app OIDC client secrets are added as each app is
  wired (Track 3/4), not in the base, so the default needs no secrets. memory storage for the lab (HA →
  postgres/kubernetes storage, later budget-enforcement hardening). See `docs/public/guides/sso-dex.md`.
- **App SSO (Track 3):** apps that speak OIDC natively talk to Dex directly, each mapping groups→roles
  in its own config: **ArgoCD** (`argocd-cm` oidc.config), **Grafana** (`[auth.generic_oauth]`),
  **Open WebUI** (`OAUTH_*`). Each is a Dex `staticClient`.
- **Forward-auth + key-portal (Track 4):** for the LiteLLM path and any non-OIDC app, **oauth2-proxy**
  runs the OIDC login against Dex and is wired as an **agentgateway `extAuthz` policy** (`AgentgatewayPolicy`,
  HTTP mode with redirect-to-signin, confirmed supported). It injects `X-Auth-Request-Email`; the
  **thin key-portal** trusts that header (only reachable through the gateway + ext-authz + SR1
  NetworkPolicy) and mints/show/rotates a LiteLLM vkey via the master key + OSS `/key/generate`.

**Why not the alternatives:** a full IdP (Authentik/Zitadel) is dashboard-first and heavyweight; the goal is federation to an *existing* IdP, not in-platform user management. Authelia can't act as a relying
party to Google. Per-app oauth2-proxy→Google (no Dex) gives no real SSO and duplicates client
registrations once >1 app needs login. Dex is the minimal central issuer that satisfies all four
constraints; oauth2-proxy stays only as the gateway forward-auth bridge.

## What the fork operator sets up

- **Default (zero setup):** `make seed-secrets` creates the static-user password/hash in the backend.
  `make credentials` writes the gitignored local credential note. Working login on clone.
- **To add SSO (opt-in):** register a **Google OAuth app** (or their IdP's) → client_id/secret → Secret
  Manager; uncomment the connector + envVars in the Dex values. **To wire an app** (ArgoCD/Grafana/etc.):
  add its `staticClient` + a generated client secret (ESO). Everything else (clients, redirect URIs,
  group→role maps) is git.

## Consequences

- One issuer to secure well; one Google registration; true SSO across the platform.
- `auth.<domain>` (ingress/domain/TLS) is a hard dependency: OIDC needs a stable HTTPS issuer.
- **SR1 NetworkPolicy** must land with the portal (Track 4), else the header-trust / budget path is
  network-bypassable and the multi-team claim is untruthful (§5d).
- CVE check: verify the pinned LiteLLM chart is patched for the flagged auth-path CVE before exposing.
- Group claims: a personal Gmail has none (operator → admin everywhere); multi-tenant roles come from
  the upstream IdP's groups, mapped per-app.
