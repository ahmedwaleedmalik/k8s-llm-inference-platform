#!/usr/bin/env bash
# Resolve and validate the dedicated, repo-scoped kubeconfig this stack deploys to.
#
# This repo never reads your global ~/.kube/config or current-context. A context switch or a
# kubeconfig overwrite in another terminal must not be able to redirect a deploy here, so the target
# is a single file (default ./kubeconfig, override with CLUSTER_KUBECONFIG) that you generate once,
# pointed at the intended cluster:
#   gcloud container clusters get-credentials <name> --region <r> --project <p> --kubeconfig=$PWD/kubeconfig
#
# Sourced by entrypoint scripts and run directly by the Makefile `require-kube` gate. Either way it
# exports KUBECONFIG, fails hard if the file is missing or the cluster is unreachable, and prints the
# resolved target so you see it before anything touches the cluster.
set -euo pipefail

_kube_target_resolve() {
  local repo_root kubeconfig ctx server
  repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
  kubeconfig="${CLUSTER_KUBECONFIG:-${repo_root}/kubeconfig}"

  if [ ! -f "${kubeconfig}" ]; then
    echo "No cluster kubeconfig at '${kubeconfig}'." >&2
    echo "This repo only talks to its own kubeconfig, never your global ~/.kube/config." >&2
    echo "Generate it once, pointed at the intended cluster:" >&2
    echo "  gcloud container clusters get-credentials <name> --region <r> --project <p> --kubeconfig='${kubeconfig}'" >&2
    echo "or point CLUSTER_KUBECONFIG at an existing kubeconfig." >&2
    return 1
  fi
  export KUBECONFIG="${kubeconfig}"

  ctx="$(kubectl config current-context 2>/dev/null || true)"
  if ! kubectl --request-timeout=5s get --raw='/readyz' >/dev/null 2>&1; then
    echo "Cluster in '${kubeconfig}' (context '${ctx:-none}') is unreachable." >&2
    echo "Regenerate it with get-credentials, or fix CLUSTER_KUBECONFIG." >&2
    return 1
  fi
  server="$(kubectl config view --minify -o jsonpath='{.clusters[0].cluster.server}' 2>/dev/null || true)"

  echo "-- kube target -------------------------------"
  echo "   kubeconfig : ${kubeconfig}"
  echo "   context    : ${ctx:-none}"
  echo "   server     : ${server:-unknown}"
  echo "----------------------------------------------"
}

_kube_target_resolve || exit 1
