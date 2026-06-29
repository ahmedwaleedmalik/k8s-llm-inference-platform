#!/usr/bin/env bash
# Platform verification — one command, plain pass/fail per plane, no Kubernetes expertise needed.
# Read-only except for an ephemeral budget-capped virtual key (used to prove budget enforcement, then
# left to expire). Domain-aware: edge/SSO checks run only when a domain is configured. Exits non-zero
# if any REQUIRED check fails (GPU-gated serving is reported, not failed). The curl calls here double
# as the copy-paste samples in the public "verify your install" guide.
set -uo pipefail
cd "$(git rev-parse --show-toplevel)"
ENV="${ENV:-ai-dev}"
domain="$(awk -F'"' '/^domain:/{print $2; exit}' "environments/${ENV}/config.yaml" 2>/dev/null || true)"
pass=0; fail=0
ok(){ printf '  \033[32m✓\033[0m %s\n' "$1"; pass=$((pass+1)); }
no(){ printf '  \033[31m✗\033[0m %s\n' "$1"; fail=$((fail+1)); }
note(){ printf '  - %s\n' "$1"; }

echo "== GitOps (Argo CD) =="
total="$(kubectl -n argocd get applications.argoproj.io --no-headers 2>/dev/null | wc -l | tr -d ' ')"
healthy="$(kubectl -n argocd get applications.argoproj.io --no-headers 2>/dev/null | awk '$2=="Synced"&&$3=="Healthy"' | wc -l | tr -d ' ')"
degraded="$(kubectl -n argocd get applications.argoproj.io --no-headers 2>/dev/null | awk '$3=="Degraded"{print $1}' | tr '\n' ' ')"
if [ "${total:-0}" -gt 0 ] && [ "${healthy:-0}" -gt 0 ]; then
  ok "Argo CD: ${healthy}/${total} apps Synced+Healthy"
  [ -n "$degraded" ] && note "degraded: $degraded"
else
  no "Argo CD: no healthy applications (is the cluster up + repo cred set?)"
fi

echo "== Economics + serving (LiteLLM) =="
mk="$(kubectl -n litellm get secret litellm-secrets -o jsonpath='{.data.PROXY_MASTER_KEY}' 2>/dev/null | openssl base64 -d -A || true)"
kubectl -n litellm port-forward svc/litellm 14998:4000 >/dev/null 2>&1 & pf=$!
trap 'kill "$pf" 2>/dev/null || true' EXIT
for _ in $(seq 1 15); do curl -fsS -m 2 http://localhost:14998/health/liveliness >/dev/null 2>&1 && break; sleep 1; done

code="$(curl -sS -m 8 -o /dev/null -w '%{http_code}' http://localhost:14998/health/liveliness)"
[ "$code" = 200 ] && ok "LiteLLM proxy healthy (/health/liveliness 200)" || no "LiteLLM proxy ($code)"

if [ -n "$mk" ]; then
  vk="$(curl -sS -m 8 http://localhost:14998/key/generate -H "Authorization: Bearer $mk" \
        -H 'Content-Type: application/json' -d '{"max_budget":0.0000005,"models":["embeddings"]}' \
        | python3 -c "import sys,json;print(json.load(sys.stdin).get('key',''))" 2>/dev/null || true)"
  if [ -n "$vk" ]; then
    c1="$(curl -sS -m 10 -o /dev/null -w '%{http_code}' http://localhost:14998/v1/embeddings -H "Authorization: Bearer $vk" -H 'Content-Type: application/json' -d '{"model":"embeddings","input":"verify one"}')"
    [ "$c1" = 200 ] && ok "Serving works through the keyed/budgeted path (embeddings 200)" || no "Serving via LiteLLM (got $c1)"
    # LiteLLM flushes spend asynchronously (ADR-0029 SR3), so a back-to-back burst can beat the write.
    # Let spend land, then a second call must be refused once accrued spend passes the cap.
    sleep 5
    c2=429
    for _ in 1 2 3; do
      c2="$(curl -sS -m 10 -o /dev/null -w '%{http_code}' http://localhost:14998/v1/embeddings -H "Authorization: Bearer $vk" -H 'Content-Type: application/json' -d '{"model":"embeddings","input":"verify over budget"}')"
      [ "$c2" = 429 ] && break; sleep 3
    done
    [ "$c2" = 429 ] && ok "Per-key budget ENFORCED (over-budget call → 429)" || no "Budget enforcement (got $c2, expected 429)"
  else
    no "Could not mint a test virtual key (master key present but /key/generate failed)"
  fi
else
  note "LiteLLM master key not found — skipping vkey/budget check"
fi
kill "$pf" 2>/dev/null || true; trap - EXIT

echo "== GPU serving (optional — informational) =="
vllm="$(kubectl -n serving get deploy raw-vllm -o jsonpath='{.status.availableReplicas}' 2>/dev/null || echo 0)"
[ "${vllm:-0}" -ge 1 ] && ok "raw-vllm available (GPU node up)" || note "raw-vllm not running (GPU scaled to zero / stocked out) — economics proven on CPU above"

echo "== Edge / SSO =="
if [ -n "$domain" ]; then
  for h in auth api chat portal argocd grafana; do
    code="$(curl -sS -m 8 -o /dev/null -w '%{http_code}' "https://${h}.${domain}" 2>/dev/null || echo 000)"
    [ "$code" != 000 ] && ok "${h}.${domain} reachable over TLS (HTTP ${code})" || no "${h}.${domain} unreachable (TLS/DNS?)"
  done
  code="$(curl -sS -m 8 -o /dev/null -w '%{http_code}' "https://auth.${domain}/.well-known/openid-configuration" 2>/dev/null || echo 000)"
  [ "$code" = 200 ] && ok "Dex OIDC discovery 200 (SSO issuer live)" || no "Dex discovery (${code})"
else
  note "no domain set → edge/SSO skipped (Tier-0 port-forward mode)"
fi

echo
echo "== ${pass} passed, ${fail} failed =="
[ "${fail:-0}" = 0 ]
