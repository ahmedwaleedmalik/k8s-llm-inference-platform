#!/usr/bin/env bash
set -euo pipefail

cd "$(git rev-parse --show-toplevel)"

TOFU="${TOFU:-$(command -v tofu || command -v terraform || true)}"
[ -n "$TOFU" ] || { echo "FAIL missing tofu/terraform"; exit 1; }

graph="$("$TOFU" -chdir=infra/gke/terraform graph -type=plan)"
edge='google_service_account_iam_member.external_secrets_workload_identity (expand)" -> "[root] google_container_cluster.main (expand)'

if printf '%s\n' "$graph" | grep -Fq "$edge"; then
  echo "OK   ESO Workload Identity binding waits for the GKE workload pool"
else
  echo "FAIL ESO Workload Identity binding does not depend on google_container_cluster.main"
  exit 1
fi
