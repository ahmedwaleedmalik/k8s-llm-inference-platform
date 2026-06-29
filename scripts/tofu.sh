#!/usr/bin/env bash
set -euo pipefail

cd "$(git rev-parse --show-toplevel)"

ENV="${ENV:-ai-dev}"
TF_DIR="${TF_DIR:-infra/gke/terraform}"
TOFU_BIN="${TOFU:-}"
if [ -z "$TOFU_BIN" ]; then
  if command -v tofu >/dev/null 2>&1; then
    TOFU_BIN="$(command -v tofu)"
  elif command -v terraform >/dev/null 2>&1; then
    TOFU_BIN="$(command -v terraform)"
  else
    TOFU_BIN="tofu"
  fi
fi

CFG="environments/${ENV}/config.yaml"
[ -f "$CFG" ] || { echo "missing $CFG" >&2; exit 1; }

field() { awk -v k="$1" '$0 ~ "(^| )"k":" { sub(".*"k":[ \t]*",""); gsub(/[ \t"]/,""); print; exit }' "$2"; }

cluster_name="$(field name "$CFG")"
project_id="$(field projectID "$CFG")"
location="$(field location "$CFG")"
if [[ "$location" =~ -[a-z]$ ]]; then
  region="${location%-*}"
else
  region="$location"
fi

export TF_VAR_cluster_name="$cluster_name"
export TF_VAR_project_id="$project_id"
export TF_VAR_location="$location"
export TF_VAR_region="$region"

cd "$TF_DIR"
exec "$TOFU_BIN" "$@"
