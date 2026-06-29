#!/usr/bin/env bash
# Pause the lab to TRUE $0: release Gateway LBs, tofu destroy the substrate, audit for orphans.
# Resume with `make resume`. See docs/public/guides/teardown.md (§C ordered teardown, §D.2 rebuild).
# GCP Secret Manager values survive (not in TF) → ESO re-materializes them on resume. LiteLLM
# Postgres data + model-cache PVCs + Artifact Registry images are DESTROYED (recreatable).
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"

ENV="${ENV:-ai-dev}"
CFG="environments/${ENV}/config.yaml"
field() { awk -v k="$1" '$0 ~ "(^| )"k":" { sub(".*"k":[ \t]*",""); sub(/[ \t,}#].*/,""); gsub(/["]/,""); print; exit }' "$CFG"; }
PROJECT="$(field projectID)"; LOCATION="$(field location)"

echo "==> [1/5] suspend Argo CD (stop selfHeal from recreating Gateways before destroy)"
kubectl -n argocd scale statefulset/argo-cd-argocd-application-controller --replicas=0 2>/dev/null || true
kubectl -n argocd scale deploy/argo-cd-argocd-applicationset-controller --replicas=0 2>/dev/null || true

echo "==> [2/5] delete all Gateways (agentgateway controller releases the data-plane LBs)"
kubectl delete gateway -A --all --ignore-not-found --wait=false 2>/dev/null || true

echo "==> [3/5] wait for forwarding-rules + reserved addresses to clear (LB footgun)"
for _ in $(seq 1 30); do
  fr="$(gcloud compute forwarding-rules list --project "$PROJECT" --format='value(name)' 2>/dev/null | grep -c . || true)"
  ad="$(gcloud compute addresses list --project "$PROJECT" --format='value(name)' 2>/dev/null | grep -c . || true)"
  echo "    forwarding-rules=$fr addresses=$ad"
  [ "$fr" = 0 ] && [ "$ad" = 0 ] && break
  sleep 10
done

echo "==> [4/6] clear PodDisruptionBudgets that would hang the node-pool drain"
# GKE node-pool deletion gracefully drains nodes; a PDB with 0 allowed disruptions blocks eviction
# and hangs `tofu destroy` for the full drain timeout. CloudNativePG ships such a PDB (litellm-pg is
# minAvailable:1, so even a 1-instance cost profile blocks), and suspending Argo above does NOT stop
# the CNPG operator from recreating it. So drop the Clusters (the PDB owner, finalizer-stripped) and
# scale the operator down, then sweep any remaining PDBs. All no-ops when CNPG / PDBs are absent.
if kubectl get crd clusters.postgresql.cnpg.io >/dev/null 2>&1; then
  for c in $(kubectl get cluster -A -o jsonpath='{range .items[*]}{.metadata.namespace}/{.metadata.name} {end}' 2>/dev/null); do
    kubectl -n "${c%%/*}" patch cluster "${c##*/}" --type=merge -p '{"metadata":{"finalizers":null}}' >/dev/null 2>&1 || true
    kubectl -n "${c%%/*}" delete cluster "${c##*/}" --ignore-not-found --wait=false >/dev/null 2>&1 || true
  done
  kubectl -n cnpg-system scale deploy --all --replicas=0 >/dev/null 2>&1 || true
fi
kubectl delete pdb -A --all --ignore-not-found >/dev/null 2>&1 || true

echo "==> [5/6] tofu destroy (cluster, node pools, node SA, ESO GSA/IAM, Artifact Registry repo)"
ENV="$ENV" TF_DIR="${TF_DIR:-infra/gke/terraform}" TOFU="${TOFU:-}" ./scripts/tofu.sh destroy -auto-approve

echo "==> [6/6] audit — delete any orphan PVC-backed disks; confirm no paid leftovers"
orphans="$(gcloud compute disks list --project "$PROJECT" --filter="name~pvc OR name~${ENV}" --format='value(name,zone)' 2>/dev/null || true)"
if [ -n "$orphans" ]; then
  echo "$orphans" | while read -r name zone; do
    [ -n "$name" ] && gcloud compute disks delete "$name" --zone "$(basename "$zone")" --project "$PROJECT" -q 2>/dev/null || true
  done
fi
echo "--- final audit (expect no rows tied to ${ENV}) ---"
gcloud compute forwarding-rules list --project "$PROJECT" 2>/dev/null || true
gcloud compute addresses        list --project "$PROJECT" 2>/dev/null || true
gcloud compute disks            list --project "$PROJECT" --filter="name~pvc OR name~${ENV}" 2>/dev/null || true
echo "paused — meter at \$0 (GSM secrets retained). Resume with: make resume"
