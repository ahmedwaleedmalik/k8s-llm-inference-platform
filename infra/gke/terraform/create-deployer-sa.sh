#!/usr/bin/env bash
# Create (or reconcile) the GCP service account that applies this OpenTofu root, with the exact
# roles the root needs. Run once per project by a project owner / IAM admin.
#
# roles/editor is NOT enough: this root writes IAM policy (project IAM members, a Workload Identity
# binding, Artifact Registry IAM) and editor omits every *.setIamPolicy permission. The role set
# below is the minimum predefined set that applies + tears down the root, plus secretmanager.admin
# for seeding secret values during bring-up.
#
# Usage:
#   PROJECT=<proj> ./create-deployer-sa.sh                 # create SA + grant roles
#   PROJECT=<proj> SA_NAME=gke-deployer ./create-deployer-sa.sh
#   PROJECT=<proj> WITH_KEY=1 ./create-deployer-sa.sh      # also mint a JSON key (leak risk; prefer WI/impersonation)
set -euo pipefail

PROJECT="${PROJECT:?set PROJECT=<gcp-project-id>}"
SA_NAME="${SA_NAME:-gke-deployer}"
SA_EMAIL="${SA_NAME}@${PROJECT}.iam.gserviceaccount.com"

ROLES=(
  roles/container.admin                    # GKE cluster + node pools
  roles/iam.serviceAccountAdmin            # create node + ESO SAs; set the WI binding (SA setIamPolicy)
  roles/iam.serviceAccountUser             # actAs the node SA when attaching it to node pools
  roles/resourcemanager.projectIamAdmin    # project IAM members (node roles, ESO secretAccessor)
  roles/artifactregistry.admin             # create the modelcar repo + grant node reader
  roles/serviceusage.serviceUsageAdmin     # enable the required project APIs
  roles/secretmanager.admin                # seed/manage secret values during bring-up
)

echo "project: $PROJECT"
echo "service account: $SA_EMAIL"

if ! gcloud iam service-accounts describe "$SA_EMAIL" --project "$PROJECT" >/dev/null 2>&1; then
  gcloud iam service-accounts create "$SA_NAME" \
    --project "$PROJECT" --display-name "GKE OpenTofu deployer"
else
  echo "  = service account already exists"
fi

for role in "${ROLES[@]}"; do
  gcloud projects add-iam-policy-binding "$PROJECT" \
    --member "serviceAccount:${SA_EMAIL}" --role "$role" \
    --condition=None --quiet >/dev/null
  echo "  ~ granted $role"
done

if [ "${WITH_KEY:-0}" = "1" ]; then
  KEY_FILE="${KEY_FILE:-${SA_NAME}-sa-key.json}"   # matches .gitignore *sa-key*.json
  gcloud iam service-accounts keys create "$KEY_FILE" \
    --iam-account "$SA_EMAIL" --project "$PROJECT"
  echo "  ~ key written to $KEY_FILE  (gitignored; export GOOGLE_APPLICATION_CREDENTIALS=\$PWD/$KEY_FILE)"
else
  echo
  echo "No key minted. Point OpenTofu at this SA via one of:"
  echo "  - Workload Identity / impersonation:  gcloud auth application-default login --impersonate-service-account=$SA_EMAIL"
  echo "  - a JSON key (leak risk):             re-run with WITH_KEY=1"
fi
