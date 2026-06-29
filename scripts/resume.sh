#!/usr/bin/env bash
# Resume from a `make pause` ($0) teardown: rebuild the substrate from OpenTofu and bring up the
# platform base. See docs/public/guides/teardown.md §D.2. The secret backend's values survived
# the pause (the store is external to the cluster), so ESO re-materializes them — no re-seeding. The
# substrate is whichever TF_DIR points at (default infra/gke/terraform; override in the environment for
# another cloud). Full rebuild ~15-20 min + model re-download.
#
# After this completes:
#   - private repo: run `make argocd-repo` (needs ARGOCD_REPO_PAT) before the apps can sync
#   - bring up more layers: make root PROFILE=serving|llm-gateway|full
#   - GPU serve / SSO need the AR images rebuilt: make modelcar-build (qwen-oci + key-portal)
#   - re-mint LiteLLM virtual keys (docs/public/guides/coder-stack.md / litellm.md)
#   - re-enable SSO/experience/demos by setting their flags in config.yaml + `make resolve-groups`
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"

echo "==> [1/5] tofu apply (recreate cluster, pools, SAs/IAM, Artifact Registry)"
make tf-init
make tf-apply

target_kubeconfig="${CLUSTER_KUBECONFIG:-$PWD/kubeconfig}"
echo "==> [2/5] fetch the dedicated cluster kubeconfig (${target_kubeconfig})"
KUBECONFIG="$target_kubeconfig" eval "$(TF_DIR="${TF_DIR:-infra/gke/terraform}" ./scripts/tofu.sh output -raw get_credentials_command)"

echo "==> [3/5] bootstrap Argo CD"
make bootstrap

echo "==> [4/5] resolve capability groups + apply the platform base"
make resolve-groups
make root PROFILE=platform

echo "==> [5/5] doctor (platform prereqs)"
make doctor PROFILE=platform || true

echo "platform base up. Next: 'make argocd-repo' (if private) then 'make root PROFILE=serving|llm-gateway|full'."
