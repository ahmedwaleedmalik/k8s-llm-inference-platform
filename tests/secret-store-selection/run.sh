#!/usr/bin/env bash
# Golden test for scripts/resolve-secret-store.sh: each secret_store_auth fixture must produce the
# expected ESO ClusterSecretStore. norm() loads YAML (drops comments) so only semantic content is
# compared. Writes into a temp OUT so the live config store is never touched.
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"
norm() { python3 -c "import sys,yaml; print(yaml.safe_dump(yaml.safe_load(open(sys.argv[1])),sort_keys=True))" "$1"; }
check() { # actual expected label
  if diff <(norm "$1") <(norm "$2") >/dev/null; then echo "OK   $3"; else
    echo "FAIL $3"; diff <(norm "$1") <(norm "$2") || true; fail=1; fi
}
fail=0

for v in workload-identity sa-key; do
  CFG="tests/secret-store-selection/fixtures/${v}.config.yaml" OUT="/tmp/${v}.css.yaml" \
    ./scripts/resolve-secret-store.sh >/dev/null
  check "/tmp/${v}.css.yaml" "tests/secret-store-selection/expected/${v}.clustersecretstore.yaml" "auth: ${v}"
done

# default (no secret_store_auth knob) must render the workload-identity store
CFG="tests/secret-store-selection/fixtures/default.config.yaml" OUT="/tmp/default.css.yaml" \
  ./scripts/resolve-secret-store.sh >/dev/null
check "/tmp/default.css.yaml" "tests/secret-store-selection/expected/workload-identity.clustersecretstore.yaml" "default → workload-identity"

# secret_backend: gcpsm renders the same gcpsm store; any other value renders the PLACEHOLDER store
CFG="tests/secret-store-selection/fixtures/backend-gcpsm.config.yaml" OUT="/tmp/backend-gcpsm.css.yaml" \
  ./scripts/resolve-secret-store.sh >/dev/null
check "/tmp/backend-gcpsm.css.yaml" "tests/secret-store-selection/expected/workload-identity.clustersecretstore.yaml" "secret_backend=gcpsm → gcpsm store"

CFG="tests/secret-store-selection/fixtures/backend-other.config.yaml" OUT="/tmp/backend-other.css.yaml" \
  ./scripts/resolve-secret-store.sh >/dev/null 2>&1
check "/tmp/backend-other.css.yaml" "tests/secret-store-selection/expected/backend-other.clustersecretstore.yaml" "secret_backend!=gcpsm → placeholder store"

exit "$fail"
