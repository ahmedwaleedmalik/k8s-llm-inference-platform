---
title: "SSO with Dex"
---

Dex (`platform/dex/`) is the platform's single OIDC issuer at `https://auth.<domain>`. Argo CD,
Grafana, Open WebUI, LiteLLM admin UI, and gateway forward-auth clients log in through it. Dex either authenticates a
**static user** (the zero-setup default) or **federates to your identity provider** (Google, GitHub,
any OIDC, LDAP, SAML). All config-as-code.

## Default: static admin user (zero setup)

A fresh fork gets working auth with no IdP. `make seed-secrets` is create-if-absent: it does not
rotate existing values. For Dex it mints a random password, stores the retrievable operator copy in
your secret backend as `dex-admin-password`, bcrypts it, stores the **hash** as `dex-admin-hash`, and
mirrors the plaintext to `secrets/dex-admin-password`:

```
  CREATED dex-admin-password
  CREATED dex-admin-hash -> login: admin@<domain> / <password>  (plaintext saved to secrets/dex-admin-password)
```

The hash is never in git. ESO (the `dex-secrets` ExternalSecret) projects only `dex-admin-hash` into
Dex as the `DEX_ADMIN_PASSWORD_HASH` env var, which `staticPasswords[].hashFromEnv` reads at startup.
The plaintext backend key is for operators and future worktrees only; `make credentials` restores it
locally from `dex-admin-password`.

Older forks may have `dex-admin-hash` but no `dex-admin-password`. That state is not recoverable
because bcrypt is one-way. Rotate once:

```sh
make reset-dex-admin
make credentials
```

The reset target writes new Secret Manager versions for both Dex admin keys, forces the ESO refresh
when the cluster is reachable, and restarts Dex if the deployment exists.

<Note>
The built-in static admin exists so a fresh install has working SSO across every component with no
external identity provider to configure. It lets you confirm the whole platform is SSO-driven
before committing to a provider. Dex persists OIDC auth-request state and refresh tokens to
Kubernetes CRDs (`config.storage.type: kubernetes` in `platform/dex/values.yaml`), so sessions and
in-flight logins survive a Dex restart. Before shared or production use, federate Dex to a real
identity provider (Google shown below) so identities are real and can be revoked centrally. You can
keep the static user alongside a connector, or remove it once federation works.
</Note>

> Needs a bcrypt tool locally (`htpasswd` from apache2-utils, or `pip install bcrypt`). If neither,
> seed-secrets prints the command to generate the hash by hand.

Login (once `domain` is set + the `edge` and `dex` apps are synced): browse any SSO-protected app and
sign in as `admin@<domain>` with the password from `make credentials`.

## How the public edge comes up

The identity, DNS, and edge Argo applications (`external-dns`, `dex`, `argocd-oidc-secret`,
`oauth2-proxy`, `edge`, `key-portal`) are **feature-gated**: `resolve-groups` only includes them when
`domain` plus the `dns`/`identity` features are enabled in `config.yaml`. When they are included they
**auto-sync**, so after `make root` the edge, OIDC, and Dex (with the static `admin` user) come up
automatically, with no manual step. With `domain` empty those apps are absent entirely and you stay in
Tier-0 (port-forward) mode with zero public exposure.

## Access model by surface

| Surface | SSO path | Authorization model |
|---|---|---|
| Open WebUI | Native OIDC to Dex | Application roles; login form disabled. |
| LiteLLM key portal | oauth2-proxy forward-auth to Dex | Any signed-in user can manage only their own virtual keys. |
| LiteLLM admin UI | Native generic OIDC to Dex | `PROXY_ADMIN_ID` maps the operator identity to admin. |
| Argo CD | Native OIDC to Dex | `policy.csv` maps `admin@<domain>` to `role:admin`. |
| Grafana | Native generic OAuth to Dex | `admin@<domain>` maps to Admin; others map to Viewer. |
| n8n | oauth2-proxy forward-auth to Dex | Public route is SSO-gated; OSS n8n still has its own owner login behind the gate. |
| Tabby | Native Tabby auth or native Tabby OIDC | Tabby SSO is Enterprise and DB-configured in Tabby's Integrations > SSO UI. The Dex `tabby` client is pre-registered, but do not use gateway forward-auth for Tabby IDE traffic. |

Common SSO means a shared identity provider, not a shared admin role. End-user portals and admin portals
must still map authorization inside the target app.

## Swap in your own SSO (Google shown)

1. **Register an OAuth app** at your provider. For Google: Cloud Console → Credentials → OAuth client
   (Web), authorized redirect URI `https://auth.<domain>/callback`. Note client_id + client_secret.
2. **Store the creds** in your secret backend (GCP Secret Manager here): `dex-google-client-id`,
   `dex-google-client-secret`. Add the matching `dex-secrets` ExternalSecret + `envVars` block.
3. **Uncomment the connector** in `platform/dex/values.yaml`:

   ```yaml
   connectors:
     - type: google          # or: github | oidc | ldap | saml
       id: google
       name: Google
       config:
         clientID: $GOOGLE_CLIENT_ID
         clientSecret: $GOOGLE_CLIENT_SECRET
         redirectURI: https://auth.<domain>/callback
   ```

   (Connector `clientSecret` expands `$ENV` automatically. Keep or drop the static user.)
4. Sync the `dex` app. Other providers: change the `type` + `config` block; the rest of the platform
   is unchanged because every app trusts Dex, not the upstream.

## Wire an app to Dex (per app)

Each app's OIDC block is already in its config as a commented **opt-in** (Track 3): additive, so the
app's built-in admin login keeps working and uncommenting can't lock you out. Per app:

1. **Generate a client secret:** `openssl rand -hex 32` → store in Secret Manager as
   `dex-<app>-client-secret`.
2. **Tell Dex about the client:** uncomment the app's `staticClient` in `platform/dex/values.yaml`
   (`secretEnv: <APP>_CLIENT_SECRET`) and add a `dex-secrets` ExternalSecret + `envVars` entry feeding
   that env. Sync `dex`.
3. **Give the app its secret + uncomment its OIDC block** (each references the runbook):
   - **Argo CD** (`bootstrap/argo-cd/values.yaml`): ESO-sync the secret into `argocd-secret` key
     `oidc.dex.clientSecret`; uncomment `configs.cm.oidc.config` + `configs.rbac.policy.csv`.
   - **Grafana** (`platform/observability/values.yaml`): ESO-sync into a `grafana-oidc` secret;
     uncomment `grafana.ini.auth.generic_oauth` + the env mapping.
   - **Open WebUI** (`experience/open-webui/deployment.yaml`): add `OAUTH_CLIENT_SECRET` to
     `openwebui-secrets`; uncomment the `OAUTH_*` env. (Already at `chat.<domain>`, no extra exposure.)
   - **Tabby** (`experience/tabby/`): Dex already has a `tabby` client with redirect
     `https://tabby.<domain>/oauth/callback/oidc`. In Tabby Enterprise, create an OIDC provider in
     Integrations > SSO using issuer `https://auth.<domain>`, client ID `tabby`, and the
     `dex-tabby-client-secret` value. This lives in Tabby's DB, not `config.toml`.
4. **Expose Argo CD / Grafana publicly** (Open WebUI already is). The OIDC redirect needs a public HTTPS
   host, so add a gateway listener + HTTPRoute for each:

   ```yaml
   # routing/edge/gateway.yaml, spec.listeners (add):
   - { name: argocd-https, port: 443, protocol: HTTPS, hostname: argocd.<domain>,
       tls: { mode: Terminate, certificateRefs: [{ name: argocd-tls }] },
       allowedRoutes: { namespaces: { from: All } } }
   # an HTTPRoute (co-located with the app's Service ns) → argocd-server:80 / the grafana svc:80
   ```

   Add the matching DNS record (`argocd.<domain>` → static IP), automatic if external-dns is on.
5. `make fork-init` (rewrites the domain from `config.yaml`), sync. Group→role mapping lives in each app's own config
   (Argo CD `policy.csv`, Grafana `role_attribute_path`).

## Go to production: federate to Google

Switching the operator identity from the built-in static user to Google (or any provider) is a single coordinated change. Each application matches the admin identity explicitly, so update them together.

1. Register a Google OAuth application with the redirect URI `https://auth.<domain>/callback`. Store the credentials in your secret backend as `dex-google-client-id` and `dex-google-client-secret`, then add them to the `dex-secrets` ExternalSecret and the matching `envVars` in `platform/dex/values.yaml`.
2. Uncomment the Google `connector` block in `platform/dex/values.yaml`.
3. Update the admin identity in each application:
   - Argo CD `policy.csv` (`bootstrap/argo-cd/values.yaml`): set the group mapping to your Google email.
   - Grafana `role_attribute_path` (`platform/observability/values.yaml`): set the email in the expression to your Google email.
   - Open WebUI: grant your Google login the admin role.
   - LiteLLM `PROXY_ADMIN_ID` (`platform/litellm/values.yaml`): change `static-admin` to your Google subject identifier (the numeric account id, visible in the LiteLLM UI after the first SSO login).
4. Optionally remove the `staticPasswords` entry from `platform/dex/values.yaml` once federation is confirmed.
