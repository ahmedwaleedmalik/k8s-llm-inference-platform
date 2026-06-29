#!/usr/bin/env bash
# Golden test for scripts/resolve-guardrails.sh (ADR-0034): the `on` fixture must render the LiteLLM
# guardrails proxy_config block; the `off` fixture must render an empty no-op overlay. Comments differ
# by CFG path, so compare the parsed YAML (norm drops comments), into a temp OUT so the live
# clusters/ai-dev overlay is never touched.
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"
norm() { python3 -c "import sys,yaml; print(yaml.safe_dump(yaml.safe_load(open(sys.argv[1])),sort_keys=True))" "$1"; }
fail=0
for fx in on on-comment off; do
  CFG="tests/guardrails-selection/fixtures/${fx}.config.yaml" OUT="/tmp/${fx}.guardrails.yaml" ./scripts/resolve-guardrails.sh >/dev/null
  expected="$fx"; [ "$fx" = on-comment ] && expected=on
  if diff <(norm "/tmp/${fx}.guardrails.yaml") <(norm "tests/guardrails-selection/expected/${expected}.litellm-guardrails.yaml") >/dev/null; then
    echo "OK   resolve-guardrails: ${fx}"
  else
    echo "FAIL resolve-guardrails: ${fx}"; diff <(norm "/tmp/${fx}.guardrails.yaml") <(norm "tests/guardrails-selection/expected/${expected}.litellm-guardrails.yaml") || true; fail=1
  fi
done
exit "$fail"
