# GKE OpenTofu root

Declarative cloud substrate for the GKE lab. This root owns **GCP resources only**:

- required project APIs
- GKE cluster with Workload Identity
- CPU platform node pool
- scale-to-zero GPU node pool
- Google service account + IAM for External Secrets Operator
- GKE node service account + Artifact Registry pull access
- Artifact Registry Docker repo for OCI modelcars

Argo CD still owns all in-cluster lifecycle: Kueue, KEDA, ESO, Prometheus/Grafana, KServe,
LiteLLM, routing, dashboards, and workloads.

## Required permissions

This root writes IAM policy (project IAM members, a Workload Identity binding, Artifact Registry
IAM), so **`roles/editor` is not sufficient** — editor omits every `*.setIamPolicy` permission and
`tofu apply` fails on the IAM resources after the cluster is built. Grant the applying identity this
predefined role set:

| Role | Covers |
|------|--------|
| `roles/container.admin` | GKE cluster + node pools |
| `roles/iam.serviceAccountAdmin` | create the node + ESO service accounts; set the WI binding (SA `setIamPolicy`) |
| `roles/iam.serviceAccountUser` | `actAs` the node SA when attaching it to node pools |
| `roles/resourcemanager.projectIamAdmin` | project IAM members (node roles, ESO `secretAccessor`) |
| `roles/artifactregistry.admin` | create the modelcar repo + grant the node reader binding |
| `roles/serviceusage.serviceUsageAdmin` | enable the required project APIs |
| `roles/secretmanager.admin` | seed/manage secret values during bring-up (not Terraform) |

Create a dedicated deployer SA with exactly these roles (idempotent; run once by a project owner):

```sh
PROJECT=ai-lab ./create-deployer-sa.sh           # SA + role bindings
PROJECT=ai-lab WITH_KEY=1 ./create-deployer-sa.sh # also mint a JSON key (leak risk)
```

Prefer Workload Identity / impersonation over a downloaded key:

```sh
gcloud auth application-default login \
  --impersonate-service-account=gke-deployer@ai-lab.iam.gserviceaccount.com
```

If IAM elevation is impossible (restricted shared project, editor-only), the IAM resources must be
pre-created out-of-band — there is no editor-only apply path for this root as written.

## Bootstrap

Enable the bootstrap API once, then apply:

```sh
export PROJECT=ai-lab
gcloud services enable serviceusage.googleapis.com cloudresourcemanager.googleapis.com --project "$PROJECT"

cp infra/gke/terraform/terraform.tfvars.example infra/gke/terraform/terraform.tfvars
$EDITOR environments/ai-dev/config.yaml          # canonical project/name/location
$EDITOR infra/gke/terraform/terraform.tfvars     # optional node/modelcar overrides
make tf-init
make tf-plan
make tf-apply                  # interactive approval; add AUTO_APPROVE=1 for non-interactive/CI
```

The Make targets inject `project_id`, `cluster_name`, `location`, and `region` from
`environments/ai-dev/config.yaml`. `terraform.tfvars` is for optional substrate overrides; if it repeats
those fields, `make config-check` enforces they match.

Get credentials:

```sh
$(make -s tf-credentials)
```

## State

Default = local state. That is simplest for a fork and avoids a bucket bootstrap loop.

For shared/team state, copy `backend.gcs.tf.example` to `backend.tf`, create the bucket manually, then
run `tofu init -migrate-state`. Do not commit fork-specific `backend.tf`.

## Secrets

Secret **values** never go in tfvars or state. This root creates IAM only. Seed values manually per the
secret contract:

```sh
make doctor PROFILE=serving
```

For a new secret value, use `gcloud secrets create <name> --data-file=- --project "$PROJECT"` (or
`gcloud secrets versions add` if the secret container already exists).
