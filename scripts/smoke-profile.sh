#!/usr/bin/env bash
set -euo pipefail

cd "$(git rev-parse --show-toplevel)"

PROFILE="${PROFILE:-platform}"

case "$PROFILE" in
  platform)
    ./scripts/doctor.sh platform
    ;;
  serving)
    ./scripts/doctor.sh serving
    ./scripts/smoke-chat.sh
    ;;
  llm-gateway)
    ./scripts/doctor.sh llm-gateway
    echo "LiteLLM smoke: follow docs/public/guides/litellm.md §3 to mint a virtual key and call /v1/chat/completions."
    ;;
  full)
    ./scripts/doctor.sh full
    ./scripts/smoke-chat.sh
    echo "Demo smoke: follow docs/public/guides/inference-gateway.md §8 for the sim-backed routing demo."
    ;;
  *)
    echo "unknown PROFILE=$PROFILE (use platform|serving|llm-gateway|full)" >&2
    exit 1
    ;;
esac
