# Hetzner OpenTofu root — cloud-agnostic portability proof

> **Primary path = [`../k3s`](../k3s) (hetzner-k3s).** This Talos/OpenTofu path is the IaC-pure alternative (needs a Talos image uploaded first).

Stands up a **Talos Linux** Kubernetes cluster on **Hetzner Cloud** (CPU-only) to prove the platform is
portable: the *same* `catalog/appsets` that run on GKE deploy here unchanged. Prod stays GKE; this cluster
is a throwaway proof. There is **no GPU** — no GPU type exists in the hcloud API, so serving
runs on CPU like the GKE GPU-stockout path.

Boundary (ADR-0028): **OpenTofu owns the cluster + cloud resources only.** This root stops at a working
kubeconfig; Argo CD owns everything in-cluster.

Built on the community module
[`hcloud-talos/terraform-hcloud-talos`](https://github.com/hcloud-talos/terraform-hcloud-talos) (pinned
**v3.4.11**), which also installs Cilium + the hcloud Cloud Controller Manager.

## Prereqs

- A **Hetzner Cloud API token** (Read & Write), from the Hetzner Cloud Console → project → Security → API
  Tokens. This is the **only** credential needed to create the cluster.
- `tofu`, `kubectl`, `talosctl` (optional, for node/OS lifecycle).

## Cluster bring-up

```sh
cp infra/hetzner/terraform/terraform.tfvars.example infra/hetzner/terraform/terraform.tfvars
export TF_VAR_hcloud_token=...   # do NOT put the token in tfvars/state
cd infra/hetzner/terraform
tofu init
tofu apply
```

Land the kubeconfig and point kubectl at it:

```sh
tofu output -raw kubeconfig   > ../../../kubeconfig.hetzner
tofu output -raw talosconfig  > ../../../talosconfig.hetzner   # for talosctl
export KUBECONFIG=$PWD/../../../kubeconfig.hetzner
# or:  $(tofu output -raw get_credentials_command)
```

## Bootstrap → make root (the portability payoff)

With `KUBECONFIG` pointed at the Hetzner cluster, the existing GitOps flow runs unchanged:

```sh
make bootstrap                 # install Argo CD on this kube-context
make resolve-groups            # generate clusters/<cluster>/groups.generated.yaml
make root PROFILE=serving      # apply AppProject + per-layer ApplicationSets
```

The **same** `catalog/appsets` reconcile here as on GKE — that *is* the proof. Argo CD installs Kueue,
KEDA, ESO, kube-prometheus-stack, KServe, vLLM (CPU), routing, etc. with no manifest changes.

## What differs from GKE (cloud-integration layer only)

| Concern | GKE | Hetzner |
|---|---|---|
| LoadBalancer | GKE LB | **hcloud CCM Cloud LB** (deployed by the module) fronts the gateway Service |
| Storage | PD / Hyperdisk (RWO) + Filestore (RWX) | **hcloud-csi RWO block only** (Argo adds it); no RWX → shared weights need self-hosted NFS/Longhorn |
| GPU | L4 node pool, scale-to-zero | **None** → CPU serving (like the GKE stockout path); no `$0`-idle (you pay per box 24/7) |
| CNI / NetworkPolicy | Dataplane-V2 (Cilium) | **Cilium** enforcing native `networking.k8s.io/v1` NetworkPolicy — parity, no CRD lock-in (ADR-0029 SR1) |
| Secrets auth | GKE Workload Identity | **static SA key** to the same GSM backend (below); ESO swap point for any backend |

Everything above the cloud-integration layer (cert-manager, KEDA, Kueue, vLLM, GIE/agentgateway,
LiteLLM, CNPG, kube-prometheus-stack) moves unchanged.

## Secrets off-GCP: ESO is the swap point; GSM + static SA key

**The portability claim lives in ESO, not the backend.** ESO is the portable interface; the
`ClusterSecretStore` is one generated file. We keep **Google Secret Manager** as the default backend
(all secrets already live there) authenticated off-GCP by a **static service-account key** — the
familiar "create key → drop in a Secret" pattern, far simpler to reproduce than Workload Identity
Federation (no pool/provider/JWKS setup). Set `secret_store_auth: sa-key` in
`environments/<env>/config.yaml` and run `make resolve-secret-store` (or `make resolve-groups`, which
chains it): it renders `platform/external-secrets/config/clustersecretstore.yaml` with the SA-key auth
block (same `metadata.name` `secret-store` as the GKE default, so a cluster has exactly one — and Argo
self-heal can't fight it because the rendered store is committed, not a manual kubectl override).

**Honest scope:** GSM is still a GCP dependency — swapping the *auth* (WIF↔key) doesn't change that.
What makes this portable is that a forker repoints the *backend* by editing this one file. ESO supports
the full spectrum, so it fits any customer with no change elsewhere:

- a cloud manager they already run — AWS Secrets Manager, Azure Key Vault, GCP SM;
- self-hosted **HashiCorp Vault / OpenBao**;
- **no secret store at all** — ESO's `kubernetes` provider (read plain in-cluster Secrets) or the
  `fake` provider (inline values). So "I just want plain secrets" is a supported, one-file choice.

We deliberately do **not** ship our own secret store (e.g. host OpenBao) — that would bloat the stack
and force an opinion the customer's infra should make.

**One-time operator setup (simpler than WIF):**

```sh
PROJECT=ai-lab
gcloud iam service-accounts create eso-hetzner --project "$PROJECT"
gcloud projects add-iam-policy-binding "$PROJECT" \
  --member "serviceAccount:eso-hetzner@$PROJECT.iam.gserviceaccount.com" \
  --role roles/secretmanager.secretAccessor
gcloud iam service-accounts keys create sa-key.json \
  --iam-account "eso-hetzner@$PROJECT.iam.gserviceaccount.com"
kubectl -n external-secrets create secret generic secret-store-key --from-file=sa-key.json=sa-key.json
rm -f sa-key.json    # the key now lives only in the cluster Secret
```

Pin ESO ≥ 2.6.0. To go fully off-GCP, swap the provider block in `scripts/resolve-secret-store.sh` per above.

## State

Default = **local state** (simplest for a fork; avoids a bucket bootstrap loop). For shared/team state,
copy `backend.gcs.tf.example` to `backend.tf`, create the bucket out-of-band, then `tofu init -migrate-state`.

## What the operator must supply

- `TF_VAR_hcloud_token` (the only thing the cluster needs).
- The one-time SA-key setup above (only if using ESO→GSM on this cluster; or swap the backend).
