#!/usr/bin/env bash
# Rotate the zero-setup Dex static admin password when the retrievable password was lost.
# This writes new Secret Manager versions for dex-admin-password and dex-admin-hash.
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"

ENV="${ENV:-ai-dev}"
CFG="${CFG:-environments/${ENV}/config.yaml}"
[ -f "$CFG" ] || { echo "reset-dex-admin: missing $CFG" >&2; exit 1; }

field() { awk -v k="$1" '$0 ~ "(^| )"k":" { sub(".*"k":[ \t]*",""); sub(/[ \t,}#].*/,""); gsub(/["]/,""); print; exit }' "$CFG"; }

BACKEND="$(field secret_backend)"; BACKEND="${BACKEND:-gcpsm}"
PROJECT="$(field projectID)"
DOMAIN="$(field domain)"
DOMAIN="${DOMAIN:-<domain>}"
DEX_HASH_KEY="dex-admin-hash"
DEX_PASSWORD_KEY="dex-admin-password"
DEX_PASSWORD_FILE="secrets/dex-admin-password"

[ "$BACKEND" = gcpsm ] || { echo "reset-dex-admin: only gcpsm is automated; rotate $DEX_PASSWORD_KEY and $DEX_HASH_KEY in backend=$BACKEND manually" >&2; exit 1; }
[ -n "$PROJECT" ] || { echo "reset-dex-admin: cluster.projectID missing in $CFG" >&2; exit 1; }
command -v gcloud >/dev/null || { echo "reset-dex-admin: gcloud not found" >&2; exit 1; }

bcrypt_hash() {
  if command -v htpasswd >/dev/null 2>&1; then
    htpasswd -bnBC 10 admin "$1" | cut -d: -f2 | sed 's/^\$2y\$/\$2a\$/'
  elif python3 -c "import bcrypt" >/dev/null 2>&1; then
    python3 -c 'import bcrypt,sys;print(bcrypt.hashpw(sys.argv[1].encode(),bcrypt.gensalt(10)).decode())' "$1"
  fi
}

put_secret_version() {
  local key="$1" value="$2"
  if gcloud secrets describe "$key" --project="$PROJECT" >/dev/null 2>&1; then
    printf '%s' "$value" | gcloud secrets versions add "$key" --project="$PROJECT" --data-file=- >/dev/null
    echo "  ROTATED $key"
  else
    printf '%s' "$value" | gcloud secrets create "$key" --project="$PROJECT" --data-file=- >/dev/null
    echo "  CREATED $key"
  fi
}

pw="$(openssl rand -hex 16)"
hash="$(bcrypt_hash "$pw")"
[ -n "$hash" ] || { echo "reset-dex-admin: no bcrypt tool found (install apache2-utils, or: pip install bcrypt)" >&2; exit 1; }

echo "reset-dex-admin ($ENV): backend=gcpsm project=$PROJECT"
put_secret_version "$DEX_PASSWORD_KEY" "$pw"
put_secret_version "$DEX_HASH_KEY" "$hash"
mkdir -p secrets
chmod 700 secrets
printf '%s\n' "$pw" > "$DEX_PASSWORD_FILE"
chmod 600 "$DEX_PASSWORD_FILE"

echo "  SAVED   $DEX_PASSWORD_FILE"
echo "  LOGIN   admin@$DOMAIN / $pw"

if kubectl -n dex get externalsecret dex-secrets >/dev/null 2>&1; then
  kubectl -n dex annotate externalsecret dex-secrets force-sync="$(date +%s)" --overwrite >/dev/null
  echo "  SYNC    forced dex-secrets ExternalSecret refresh"
fi

deploys="$(kubectl -n dex get deploy -l app.kubernetes.io/name=dex -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null || true)"
if [ -z "$deploys" ] && kubectl -n dex get deploy dex >/dev/null 2>&1; then
  deploys="dex"
fi
if [ -n "$deploys" ]; then
  while IFS= read -r deploy; do
    [ -n "$deploy" ] || continue
    kubectl -n dex rollout restart "deploy/$deploy" >/dev/null
    echo "  RESTART deploy/$deploy"
  done <<EOF
$deploys
EOF
else
  echo "  NOTE    Dex deployment not found/running; Argo/ESO will use the new hash on next sync/start"
fi
