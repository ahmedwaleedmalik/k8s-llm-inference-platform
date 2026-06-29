#!/usr/bin/env bash
# Collate operator credentials into the gitignored secrets/ dir. PASSWORD-AUTH BOOTSTRAP ONLY — the
# platform's intended access path is SSO via Dex; once apps are wired to OIDC none of these static
# passwords are needed. Argo CD's admin password is read live from the cluster each run; the Dex
# static-user password is retrieved from the secret backend into secrets/dex-admin-password and
# surfaced here. Requires: kubectl.
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"
mkdir -p secrets
OUT="secrets/credentials.local.md"
ENV="${ENV:-ai-dev}"
CFG="environments/${ENV}/config.yaml"
field() { awk -v k="$1" '$0 ~ "(^| )"k":" { sub(".*"k":[ \t]*",""); sub(/[ \t,}#].*/,""); gsub(/["]/,""); print; exit }' "$CFG"; }

domain="$(field domain 2>/dev/null || true)"
domain="${domain:-<domain>}"
backend="$(field secret_backend 2>/dev/null || true)"
backend="${backend:-gcpsm}"
project="$(field projectID 2>/dev/null || true)"

argocd_pw="$(kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' 2>/dev/null | openssl base64 -d -A || true)"
dex_pw="$(cat secrets/dex-admin-password 2>/dev/null || true)"
if [ -z "$dex_pw" ] && [ "$backend" = gcpsm ] && [ -n "$project" ] && command -v gcloud >/dev/null 2>&1; then
  dex_pw="$(gcloud secrets versions access latest --secret=dex-admin-password --project="$project" 2>/dev/null || true)"
  if [ -n "$dex_pw" ]; then
    printf '%s\n' "$dex_pw" > secrets/dex-admin-password
    chmod 600 secrets/dex-admin-password
  fi
fi

{
  echo "# Local credentials — gitignored, never commit"
  echo
  echo "> Password-auth bootstrap only. The platform's real access path is **SSO (Dex)**; once Argo CD,"
  echo "> Grafana, etc. are wired to OIDC, none of these static passwords are needed."
  echo
  echo "## Argo CD"
  echo "- URL: https://argocd.${domain}  (or \`make argocd-ui\` → http://localhost:8080)"
  if [ -n "$argocd_pw" ]; then
    echo "- user: \`admin\`"
    echo "- password: \`${argocd_pw}\`"
  else
    echo "- SSO-only: built-in admin is disabled (\`admin.enabled: \"false\"\`), so there is no static password; sign in via Dex. Break-glass: re-enable admin in \`bootstrap/argo-cd/values.yaml\` and re-run."
  fi
  echo
  echo "## Dex / portal SSO"
  echo "- portal: https://portal.${domain}  ·  issuer: https://auth.${domain}"
  echo "- email: \`admin@${domain}\`"
  if [ -n "$dex_pw" ]; then
    echo "- password: \`${dex_pw}\`"
  else
    echo "- password: unavailable — run \`make seed-secrets\`; if the backend has only legacy \`dex-admin-hash\`, run \`make reset-dex-admin\`."
  fi
} > "$OUT"
echo "credentials → $OUT"
