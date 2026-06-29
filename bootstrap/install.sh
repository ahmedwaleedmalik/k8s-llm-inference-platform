#!/usr/bin/env bash
# Bootstrap Argo CD on the repo's dedicated cluster (./kubeconfig; see scripts/kube-target.sh). Idempotent.
set -euo pipefail

CHART_VERSION="9.5.21"
NAMESPACE="argocd"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Resolve + validate the dedicated cluster: exports KUBECONFIG, prints the target, and fails hard if
# ./kubeconfig is missing or unreachable. Never uses your global current-context.
# shellcheck disable=SC1091
. "${SCRIPT_DIR}/../scripts/kube-target.sh"

helm repo add argo https://argoproj.github.io/argo-helm >/dev/null 2>&1 || true
helm repo update argo >/dev/null

# redisSecretInit is disabled in values.yaml (its Helm hook hangs Argo CD once it self-manages this
# chart), so neither the chart nor ESO creates the argocd-redis auth secret here: Argo CD's own redis
# must be up before Argo can deploy ESO, so this secret has to exist at bootstrap. Create it directly,
# create-if-absent (re-runs and restarts must not rotate a live password mid-flight). Upstream's
# sanctioned path when the hook is off: manage argocd-redis yourself.
kubectl create namespace "${NAMESPACE}" --dry-run=client -o yaml | kubectl apply -f - >/dev/null
if ! kubectl -n "${NAMESPACE}" get secret argocd-redis >/dev/null 2>&1; then
  kubectl -n "${NAMESPACE}" create secret generic argocd-redis \
    --from-literal=auth="$(openssl rand -hex 24)"
  echo "Created argocd-redis auth secret (redisSecretInit disabled)."
fi

helm upgrade --install argo-cd argo/argo-cd \
  --version "${CHART_VERSION}" \
  --namespace "${NAMESPACE}" --create-namespace \
  -f "${SCRIPT_DIR}/argo-cd/values.yaml" \
  --wait

echo
echo "Argo CD ${CHART_VERSION} installed in namespace '${NAMESPACE}'."
if kubectl -n "${NAMESPACE}" get secret argocd-initial-admin-secret >/dev/null 2>&1; then
  echo "Admin password:"
  kubectl -n "${NAMESPACE}" get secret argocd-initial-admin-secret \
    -o jsonpath='{.data.password}' | openssl base64 -d -A; echo
  echo "UI: kubectl -n ${NAMESPACE} port-forward svc/argo-cd-argocd-server 8080:80  ->  http://localhost:8080 (user: admin)"
else
  echo "Built-in admin is disabled; no argocd-initial-admin-secret was created."
  echo "UI after identity sync: https://argocd.<your-domain> (Dex SSO)"
fi
