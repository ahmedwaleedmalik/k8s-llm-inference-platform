#!/usr/bin/env bash
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"
norm() { python3 -c "import sys,yaml; print(yaml.safe_dump(yaml.safe_load(open(sys.argv[1])),sort_keys=True))" "$1"; }
fail=0
for fx in all-on minimal commented-key; do
  CFG="tests/feature-selection/fixtures/${fx}.config.yaml" OUT="/tmp/${fx}.groups.yaml" ./scripts/resolve-groups.sh >/dev/null
  if diff <(norm "/tmp/${fx}.groups.yaml") <(norm "tests/feature-selection/expected/${fx}.groups.yaml") >/dev/null; then
    echo "OK   resolver: ${fx}"
  else
    echo "FAIL resolver: ${fx}"; diff <(norm "/tmp/${fx}.groups.yaml") <(norm "tests/feature-selection/expected/${fx}.groups.yaml") || true; fail=1
  fi
done

warn="$(CFG=tests/feature-selection/fixtures/warn.config.yaml OUT=/tmp/warn.groups.yaml ./scripts/resolve-groups.sh)"
echo "$warn" | grep -q "dns enabled but dns.provider=none" && echo "OK   warn: provider-none" || { echo "FAIL warn: provider-none"; fail=1; }
echo "$warn" | grep -q "identity enabled but domain is empty" && echo "OK   warn: domain-empty" || { echo "FAIL warn: domain-empty"; fail=1; }

exit "$fail"
