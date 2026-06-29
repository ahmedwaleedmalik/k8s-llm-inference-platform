#!/usr/bin/env bash
set -euo pipefail

cd "$(git rev-parse --show-toplevel)"

ENV="${ENV:-ai-dev}"
CFG="environments/${ENV}/config.yaml"
[ -f "$CFG" ] || { echo "missing $CFG" >&2; exit 1; }

field() { awk -v k="$1" '$0 ~ "(^| )"k":" { sub(".*"k":[ \t]*",""); gsub(/[ \t"]/,""); print; exit }' "$2"; }

cluster_name="$(field name "$CFG")"
project_id="$(field projectID "$CFG")"
location="$(field location "$CFG")"
repo_url="$(field repoURL "$CFG")"

fail=0

check_nonempty() {
  local label="$1" value="$2"
  if [ -z "$value" ]; then
    echo "FAIL $label is empty"
    fail=1
  else
    echo "OK   $label=$value"
  fi
}

check_nonempty "cluster.name" "$cluster_name"
check_nonempty "cluster.projectID" "$project_id"
check_nonempty "cluster.location" "$location"
check_nonempty "repoURL" "$repo_url"

if ! [[ "$project_id" =~ ^[a-z][a-z0-9-]{4,28}[a-z0-9]$ ]]; then
  echo "FAIL cluster.projectID does not look like a GCP project ID"
  fail=1
fi

if ! [[ "$location" =~ ^[a-z]+-[a-z0-9]+[0-9]-[a-z]$ ]]; then
  echo "FAIL cluster.location should be a zone like us-central1-a"
  fail=1
fi

gpu_stack="$(field gpu_stack "$CFG")"; gpu_stack="${gpu_stack:-gke-managed}"
case "$gpu_stack" in
  gke-managed|operator|none) echo "OK   gpu_stack=$gpu_stack" ;;
  *) echo "FAIL gpu_stack=$gpu_stack — use gke-managed|operator|none"; fail=1 ;;
esac

appset_repo="$(field repoURL "clusters/${ENV}/appsets/platform.yaml")"
if [ "$repo_url" != "$appset_repo" ]; then
  echo "FAIL repoURL drift: config=$repo_url appset=$appset_repo"
  fail=1
else
  echo "OK   repoURL propagated to appsets/platform.yaml"
fi

store_project="$(field projectID platform/external-secrets/config/clustersecretstore.yaml)"
if [ "$project_id" != "$store_project" ]; then
  echo "FAIL projectID drift: config=$project_id ClusterSecretStore=$store_project"
  fail=1
else
  echo "OK   projectID propagated to ClusterSecretStore"
fi

gsa="external-secrets@${project_id}.iam.gserviceaccount.com"
if ! grep -q "$gsa" platform/external-secrets/values.yaml; then
  echo "FAIL ESO GSA annotation does not match $gsa"
  fail=1
else
  echo "OK   ESO GSA annotation matches projectID"
fi

if [ -f infra/gke/terraform/terraform.tfvars ]; then
  tf_project="$(awk -F= '/^project_id[ \t]*=/{gsub(/[ \t"]/, "", $2); print $2; exit}' infra/gke/terraform/terraform.tfvars)"
  tf_cluster="$(awk -F= '/^cluster_name[ \t]*=/{gsub(/[ \t"]/, "", $2); print $2; exit}' infra/gke/terraform/terraform.tfvars)"
  tf_location="$(awk -F= '/^location[ \t]*=/{gsub(/[ \t"]/, "", $2); print $2; exit}' infra/gke/terraform/terraform.tfvars)"

  [ -z "$tf_project" ] || [ "$tf_project" = "$project_id" ] || { echo "FAIL terraform.tfvars project_id drift: $tf_project"; fail=1; }
  [ -z "$tf_cluster" ] || [ "$tf_cluster" = "$cluster_name" ] || { echo "FAIL terraform.tfvars cluster_name drift: $tf_cluster"; fail=1; }
  [ -z "$tf_location" ] || [ "$tf_location" = "$location" ] || { echo "FAIL terraform.tfvars location drift: $tf_location"; fail=1; }
  echo "OK   terraform.tfvars checked"
fi

exit "$fail"
