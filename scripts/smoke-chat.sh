#!/usr/bin/env bash
# Smoke-test the raw vLLM endpoint end-to-end: port-forward the in-cluster Service,
# send an OpenAI-compatible chat request with the ESO-provisioned API key, assert a
# non-empty completion. Proves the serving contract (out-of-cluster, authenticated).
#   ./scripts/smoke-chat.sh
# Prereq: the raw-vllm app is Synced/Healthy and the L4 node is up (Deployment scaled >0).
set -euo pipefail

NS="${NS:-serving}"
SVC="${SVC:-raw-vllm}"
PORT="${PORT:-8000}"
MODEL="${MODEL:-qwen2.5-0.5b-instruct}"

KEY="${VLLM_API_KEY:-$(kubectl -n "$NS" get secret vllm-api-key -o jsonpath='{.data.api-key}' | openssl base64 -d -A)}"
[ -n "$KEY" ] || { echo "no API key (set VLLM_API_KEY or create the vllm-api-key secret)"; exit 1; }

kubectl -n "$NS" port-forward "svc/$SVC" "$PORT:$PORT" >/dev/null 2>&1 &
PF_PID=$!
trap 'kill "$PF_PID" 2>/dev/null || true' EXIT

for _ in $(seq 1 30); do
  curl -sf "http://localhost:$PORT/health" >/dev/null 2>&1 && break
  sleep 1
done

RESP=$(curl -sf "http://localhost:$PORT/v1/chat/completions" \
  -H "Authorization: Bearer $KEY" \
  -H "Content-Type: application/json" \
  -d "{\"model\":\"$MODEL\",\"messages\":[{\"role\":\"user\",\"content\":\"Reply with exactly: pong\"}],\"max_tokens\":16,\"temperature\":0}")

echo "$RESP"
CONTENT=$(echo "$RESP" | python3 -c 'import sys,json;print(json.load(sys.stdin)["choices"][0]["message"]["content"])')
[ -n "$CONTENT" ] || { echo "FAIL: empty completion"; exit 1; }
echo "SMOKE PASSED: model replied: $CONTENT"
