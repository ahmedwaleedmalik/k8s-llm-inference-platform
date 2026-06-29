#!/usr/bin/env bash
# OPTIONAL manual override. The in-cluster litellm-keys Job (experience/litellm-keys) mints the
# experience virtual keys automatically; this script re-mints open-webui's secret by hand (e.g. after
# rotating the master key). open-webui's OPENAI_API_KEY is a freshly-minted LiteLLM virtual key (so all
# its chat traffic is keyed + budgeted), and WEBUI_SECRET_KEY is a random session signer. Idempotent —
# re-running rotates both. Run after the llm-gateway layer is up. Requires: kubectl, curl, openssl.
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"

NS="${NS:-experience}"
LITELLM_NS="${LITELLM_NS:-litellm}"
PORT="${PORT:-14999}"

master_key="$(kubectl -n "$LITELLM_NS" get secret litellm-secrets -o jsonpath='{.data.PROXY_MASTER_KEY}' | openssl base64 -d -A)"
[ -n "$master_key" ] || { echo "no LiteLLM master key — is the llm-gateway layer up?" >&2; exit 1; }

kubectl -n "$LITELLM_NS" port-forward svc/litellm "$PORT:4000" >/dev/null 2>&1 &
pf=$!; trap 'kill "$pf" 2>/dev/null || true' EXIT
for _ in $(seq 1 15); do curl -fsS -m 2 "http://localhost:$PORT/health/liveliness" >/dev/null 2>&1 && break; sleep 1; done

vkey="$(curl -fsS "http://localhost:$PORT/key/generate" \
  -H "Authorization: Bearer $master_key" -H 'Content-Type: application/json' \
  -d '{"metadata":{"app":"open-webui"}}' | python3 -c "import sys,json;print(json.load(sys.stdin)['key'])")"
[ -n "$vkey" ] || { echo "vkey mint failed" >&2; exit 1; }

kubectl -n "$NS" create secret generic openwebui-secrets \
  --from-literal=OPENAI_API_KEY="$vkey" \
  --from-literal=WEBUI_SECRET_KEY="$(openssl rand -hex 32)" \
  --dry-run=client -o yaml | kubectl apply -f -

echo "seed-experience-secrets ($NS): openwebui-secrets applied (minted LiteLLM vkey + random session key)"
