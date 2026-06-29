#!/usr/bin/env bash
# Seed the INTERNAL RANDOM secrets every ExternalSecret references into the active secret backend,
# idempotently (create-if-absent, never overwrite). These have no external provider — they are random
# values the platform mints for itself (LiteLLM master/salt keys, the internal vLLM key, the
# oauth2-proxy cookie secret, the Dex OIDC client secrets, the Postgres passwords, n8n's encryption
# key). A forker runs this
# once and is then left with only the REAL external secrets to hand-create (printed at the end).
#
# Backend: reads `secret_backend` from config.yaml (default gcpsm). gcpsm seeds via `gcloud secrets`.
# Any other backend has no assumed CLI — we print the keys + the ESO docs link instead.
# No new deps (awk + openssl + gcloud only).
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"

ENV="${ENV:-ai-dev}"
CFG="${CFG:-environments/${ENV}/config.yaml}"
[ -f "$CFG" ] || { echo "seed-secrets: missing $CFG" >&2; exit 1; }

field() { awk -v k="$1" '$0 ~ "(^| )"k":" { sub(".*"k":[ \t]*",""); sub(/[ \t,}#].*/,""); gsub(/["]/,""); print; exit }' "$CFG"; }

BACKEND="$(field secret_backend)"; BACKEND="${BACKEND:-gcpsm}"
PROJECT="$(field projectID)"
DOMAIN="$(field domain)"
DOMAIN="${DOMAIN:-<domain>}"
DNS_AUTOMATE="$(field automate)"
DNS_PROVIDER="$(field provider)"

# Internal randoms: every remoteRef.key with no external provider (cross-checked against the
# repo-wide ExternalSecret manifests). hex32 = 64 hex chars; the oauth2-proxy cookie secret must be
# exactly 16/24/32 bytes as read by oauth2-proxy, so use 32 printable bytes.
HEX_KEYS="litellm-master-key litellm-salt-key vllm-api-key litellm-db-password litellm-grafana-ro-password dex-oauth2-proxy-client-secret dex-argocd-client-secret dex-litellm-client-secret dex-grafana-client-secret dex-open-webui-client-secret dex-tabby-client-secret n8n-encryption-key"
COOKIE_KEY="oauth2-proxy-cookie-secret"
DEX_HASH_KEY="dex-admin-hash"
DEX_PASSWORD_KEY="dex-admin-password"
DEX_PASSWORD_FILE="secrets/dex-admin-password"

gen() { case "$1" in "$COOKIE_KEY") openssl rand -hex 16 | tr -d '\n' ;; *) openssl rand -hex 32 | tr -d '\n' ;; esac; }

# Dex static admin: Dex reads only the bcrypt HASH (staticPasswords[].hashFromEnv). The plaintext
# password is also kept in the backend so future worktrees/agents can retrieve it without guessing.
# bcrypt via htpasswd (apache2-utils) or python3-bcrypt; $2y$→$2a$ for Go/Dex compatibility.
bcrypt_hash() { # plaintext -> bcrypt hash on stdout, "" if no tool
  if command -v htpasswd >/dev/null 2>&1; then
    htpasswd -bnBC 10 admin "$1" | cut -d: -f2 | sed 's/^\$2y\$/\$2a\$/'
  elif python3 -c "import bcrypt" >/dev/null 2>&1; then
    python3 -c 'import bcrypt,sys;print(bcrypt.hashpw(sys.argv[1].encode(),bcrypt.gensalt(10)).decode())' "$1"
  fi
}

if [ "$BACKEND" != gcpsm ]; then
  echo "seed-secrets ($ENV): secret_backend=$BACKEND — no assumed CLI for this backend."
  echo "Create these internal secrets in your backend (random values; see ESO https://external-secrets.io/latest/provider/):"
  for k in $HEX_KEYS; do echo "  - $k        (random, e.g. openssl rand -hex 32)"; done
  echo "  - $COOKIE_KEY  (random 32-byte value, e.g. openssl rand -hex 16)"
  echo "  - $DEX_PASSWORD_KEY  (random admin password; durable operator copy)"
  echo "  - $DEX_HASH_KEY  (bcrypt HASH of $DEX_PASSWORD_KEY: htpasswd -bnBC 10 admin '<pw>' | cut -d: -f2  → \$2a\$ form)"
  echo
else
  [ -n "$PROJECT" ] || { echo "seed-secrets: cluster.projectID missing in $CFG" >&2; exit 1; }
  command -v gcloud >/dev/null || { echo "seed-secrets: gcloud not found (needed for secret_backend=gcpsm)" >&2; exit 1; }
  echo "seed-secrets ($ENV): backend=gcpsm project=$PROJECT — seeding internal randoms (create-if-absent)"
  secret_exists() { gcloud secrets describe "$1" --project="$PROJECT" >/dev/null 2>&1; }
  secret_value() { gcloud secrets versions access latest --secret="$1" --project="$PROJECT"; }
  write_local_dex_password() { mkdir -p secrets && chmod 700 secrets && printf '%s\n' "$1" > "$DEX_PASSWORD_FILE" && chmod 600 "$DEX_PASSWORD_FILE"; }
  create_secret() { printf '%s' "$2" | gcloud secrets create "$1" --project="$PROJECT" --data-file=- >/dev/null; }

  seed() { # key
    if secret_exists "$1"; then
      echo "  EXISTS  $1"
    else
      gen "$1" | gcloud secrets create "$1" --project="$PROJECT" --data-file=- >/dev/null
      echo "  CREATED $1"
    fi
  }
  for k in $HEX_KEYS; do seed "$k"; done
  seed "$COOKIE_KEY"

  # Dex admin: create-if-absent. Store both the retrievable operator password and Dex's bcrypt hash.
  # Existing hash-only installs cannot be recovered because bcrypt is one-way; rotate them explicitly.
  dex_hash_exists=false
  dex_password_exists=false
  secret_exists "$DEX_HASH_KEY" && dex_hash_exists=true
  secret_exists "$DEX_PASSWORD_KEY" && dex_password_exists=true

  if [ "$dex_password_exists" = true ]; then
    pw="$(secret_value "$DEX_PASSWORD_KEY")"
    write_local_dex_password "$pw"
    echo "  EXISTS  $DEX_PASSWORD_KEY (restored $DEX_PASSWORD_FILE)"
  fi

  if [ "$dex_hash_exists" = true ] && [ "$dex_password_exists" = true ]; then
    echo "  EXISTS  $DEX_HASH_KEY"
  elif [ "$dex_hash_exists" = true ]; then
    echo "  EXISTS  $DEX_HASH_KEY"
    echo "  ! MISSING $DEX_PASSWORD_KEY: legacy hash-only state; bcrypt is one-way."
    echo "    Run: make reset-dex-admin"
  elif [ "$dex_password_exists" = true ]; then
    hash="$(bcrypt_hash "$pw")"
    if [ -n "$hash" ]; then
      create_secret "$DEX_HASH_KEY" "$hash"
      echo "  CREATED $DEX_HASH_KEY from $DEX_PASSWORD_KEY"
    else
      echo "  ! $DEX_HASH_KEY: no bcrypt tool found (install apache2-utils, or: pip install bcrypt)"
    fi
  else
    pw="$(openssl rand -hex 16)"
    hash="$(bcrypt_hash "$pw")"
    if [ -n "$hash" ]; then
      create_secret "$DEX_PASSWORD_KEY" "$pw"
      create_secret "$DEX_HASH_KEY" "$hash"
      write_local_dex_password "$pw"
      echo "  CREATED $DEX_PASSWORD_KEY"
      echo "  CREATED $DEX_HASH_KEY → login: admin@$DOMAIN / $pw  (plaintext saved to $DEX_PASSWORD_FILE)"
    else
      echo "  ! $DEX_HASH_KEY: no bcrypt tool found (install apache2-utils, or: pip install bcrypt) — create it by hand:"
      echo "    printf '%s' '<pw>' | gcloud secrets create $DEX_PASSWORD_KEY --project=$PROJECT --data-file=-"
      echo "    htpasswd -bnBC 10 admin '<pw>' | cut -d: -f2 | sed 's/^\$2y\$/\$2a\$/' | gcloud secrets create $DEX_HASH_KEY --project=$PROJECT --data-file=-"
    fi
  fi
  echo
fi

# Real EXTERNAL secrets: never auto-generated — the forker supplies their own values.
echo "Provide these yourself (real external credentials — seed-secrets does NOT generate them):"
need=0
if [ "$DNS_AUTOMATE" = true ] && [ "$DNS_PROVIDER" = cloudflare ]; then
  echo "  - cloudflare-api-token   (dns.automate + dns.provider=cloudflare): Cloudflare API token, Zone:DNS:Edit"
  need=$((need + 1))
fi
echo "  - anthropic-api-key      (only if using the Anthropic egress provider): sk-ant-..."
echo "  - hf-token               (only for gated Hugging Face models): hf_..."
echo
echo "Create each in the active backend, e.g. (gcpsm):"
echo "  echo -n '<value>' | gcloud secrets create <key> --project=$PROJECT --data-file=-"
echo "Required-now count depends on which providers you use: cloudflare token is $([ "$need" -eq 1 ] && echo "needed" || echo "not needed") for this config; anthropic/hf only if you use them."
