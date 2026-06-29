#!/usr/bin/env bash
# Resolve config.yaml `features:` into clusters/<env>/groups.generated.yaml — the array the per-layer
# ApplicationSets read (ADR-0031). `-core` groups are always enabled. Optional groups come from
# `features:`. Domain-dependent groups warn (not fail) when domain is unset — they are manual-sync
# (dormant) and need a domain to function anyway. No new deps (awk only).
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"

ENV="${ENV:-ai-dev}"
CFG="${CFG:-environments/${ENV}/config.yaml}"
OUT="${OUT:-clusters/${ENV}/groups.generated.yaml}"
[ -f "$CFG" ] || { echo "resolve-groups: missing $CFG" >&2; exit 1; }

field() { awk -v k="$1" '$0 ~ "(^| )"k":" { sub(".*"k":[ \t]*",""); sub(/[ \t,}#].*/,""); gsub(/["]/,""); print; exit }' "$CFG"; }
feat() { # feature-name default  -> "true"/"false"
  local v; v="$(awk -v k="$1" '$0 ~ "^  "k":" { sub("^  "k":[ \t]*",""); gsub(/[ \t"#].*$/,""); print; exit }' "$CFG")"
  case "$v" in true) echo true;; false) echo false;; *) echo "$2";; esac
}

DOMAIN="$(field domain)"; PROVIDER="$(field provider)"
GPU_STACK="$(field gpu_stack)"; GPU_STACK="${GPU_STACK:-gke-managed}"

# group | layer | kind(core/opt) | feature-flag | default. The gpu-operator group is gated by the
# gpu_stack knob (enabled only when gpu_stack=operator), not a features: boolean — handled in the loop.
TABLE="
platform-core|platform|core||true
autoscaling|platform|opt|autoscaling|true
identity|platform|opt|identity|false
dns|platform|opt|dns|false
security|platform|opt|security|false
opencost|platform|opt|opencost|false
gpu-operator|platform|opt|gpu_stack|false
serving-core|serving|core||true
kserve|serving|opt|kserve|true
embeddings|serving|opt|embeddings|true
coding-assistant|serving|opt|coding-assistant|false
llm-d|serving|opt|llm-d|false
routing-core|routing|core||true
public-edge|routing|opt|public-edge|false
mcp-gateway|routing|opt|mcp-gateway|false
egress|routing|opt|egress|false
llm-gateway-core|llm-gateway|core||true
guardrails|llm-gateway|opt|guardrails|false
experience|experience|opt|experience|false
n8n|experience|opt|n8n|false
demos|demos|opt|demos|false
"

tmp="$(mktemp)"
trap 'rm -f "$tmp"' EXIT
warns=""
while IFS='|' read -r name layer kind flag def; do
  [ -n "$name" ] || continue
  if [ "$name" = gpu-operator ]; then enabled="$([ "$GPU_STACK" = operator ] && echo true || echo false)"
  elif [ "$kind" = core ]; then enabled=true; else enabled="$(feat "$flag" "$def")"; fi
  printf -- '- { name: %s, layer: %s, enabled: "%s", catalogPath: clusters/%s/catalog/%s }\n' \
    "$name" "$layer" "$enabled" "$ENV" "$name" >>"$tmp"
  # dependency / domain warnings (non-fatal)
  if [ "$enabled" = true ]; then
    case "$name" in
      identity|dns|public-edge) [ -n "$DOMAIN" ] || warns="${warns}  ! $name enabled but domain is empty — stays dormant until domain is set\n";;
    esac
    [ "$name" != dns ] || [ "$PROVIDER" != none ] || warns="${warns}  ! dns enabled but dns.provider=none\n"
    [ "$name" != coding-assistant ] || warns="${warns}  i coding-assistant: ensure the llm-gateway layer is applied (models route through LiteLLM)\n"
    [ "$name" != llm-d ] || warns="${warns}  i llm-d: advanced disaggregated serving — needs the kserve group (LLMInferenceService CRD) + >=2 GPUs (1 prefill + 1 decode); manual-sync, stays dormant on the single-GPU lab\n"
    [ "$name" != experience ] || warns="${warns}  i experience: needs the llm-gateway layer; key-portal needs identity\n"
    [ "$name" != security ] || warns="${warns}  i security: needs the serving + llm-gateway layers (NetworkPolicies target serving/inference); label tenant ns llm-platform/kueue-managed=true to gate GPU pods\n"
    [ "$name" != mcp-gateway ] || warns="${warns}  i mcp-gateway: auto-syncs at wave 5; needs routing-core (shared inference-gateway) + identity (Dex JWKS) up first; tracing is gateway-wide via agentgateway chart values + an OTLP target (see routing/mcp-gateway/README.md)\n"
    [ "$name" != guardrails ] || warns="${warns}  i guardrails: deploys Presidio (analyzer+anonymizer) and injects the LiteLLM guardrails block via litellm-guardrails.generated.yaml — run make resolve-groups to (re)generate it; needs the llm-gateway layer (guardrails live in the LiteLLM /v1 edge)\n"
    [ "$name" != n8n ] || warns="${warns}  i n8n: manual-sync automation surface; needs identity/oauth2-proxy for SSO gate, llm-gateway for LiteLLM-only AI calls, and n8n-encryption-key in the secret backend\n"
    [ "$name" != egress ] || warns="${warns}  i egress: external-provider egress (Anthropic via agentgateway, ADR-0013) — needs the anthropic-api-key secret in the backend, else its ExternalSecret degrades; the claude-haiku LiteLLM model only routes when this is on\n"
    [ "$name" != gpu-operator ] || warns="${warns}  i gpu-operator (gpu_stack=operator): self-managed NVIDIA GPU Operator for non-GKE substrates; needs node prerequisites (kernel headers, Secure Boot off on Ada). On GKE leave gpu_stack=gke-managed. See ADR-0001.\n"
  fi
done <<< "$TABLE"

mv "$tmp" "$OUT"
echo "resolve-groups ($ENV): wrote $OUT"
[ -z "$warns" ] || printf "%b" "$warns"
