#!/usr/bin/env bash
# Golden test for scripts/resolve-profile.sh: each profile fixture must produce the expected litellm
# values overlay + CNPG db kustomization (and prod a ScheduledBackup). Runs into a temp DB_DIR so the
# live platform/litellm/db is never touched.
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"
norm() { python3 -c "import sys,yaml; docs=[d for d in yaml.safe_load_all(open(sys.argv[1])) if d]; print(yaml.safe_dump_all(docs,sort_keys=True))" "$1"; }
check() { # actual expected label
  if diff <(norm "$1") <(norm "$2") >/dev/null; then echo "OK   $3"; else
    echo "FAIL $3"; diff <(norm "$1") <(norm "$2") || true; fail=1; fi
}
fail=0
for p in cost prod; do
  tmpdb="$(mktemp -d)"
  CFG="tests/profile-selection/fixtures/${p}.config.yaml" \
    VALUES_OUT="/tmp/${p}.litellm-profile.yaml" \
    DB_DIR="$tmpdb" ./scripts/resolve-profile.sh >/dev/null
  check "/tmp/${p}.litellm-profile.yaml" "tests/profile-selection/expected/${p}.litellm-profile.yaml" "${p}: litellm overlay"
  check "$tmpdb/kustomization.yaml" "tests/profile-selection/expected/${p}.db-kustomization.yaml" "${p}: db kustomization"
  if [ "$p" = prod ]; then
    check "$tmpdb/scheduledbackup.generated.yaml" "tests/profile-selection/expected/prod.scheduledbackup.yaml" "prod: scheduledbackup"
  else
    [ ! -f "$tmpdb/scheduledbackup.generated.yaml" ] && echo "OK   cost: no scheduledbackup" || { echo "FAIL cost: scheduledbackup leaked"; fail=1; }
  fi
  rm -rf "$tmpdb"
done
exit "$fail"
