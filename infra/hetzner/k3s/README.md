# Hetzner k3s — cloud-agnostic portability proof (PRIMARY path)

Stands up a **k3s** Kubernetes cluster on **Hetzner Cloud** (CPU-only) with
[`vitobotta/hetzner-k3s`](https://github.com/vitobotta/hetzner-k3s) to prove the platform is
portable: the *same* `catalog/appsets` that run on GKE reconcile here unchanged. Prod stays GKE; this
cluster is a throwaway proof. There is **no GPU** — no GPU type exists in the hcloud API, so
serving runs on CPU like the GKE GPU-stockout path.

Pinned to **hetzner-k3s v2.6.0** (config schema:
<https://github.com/vitobotta/hetzner-k3s/blob/v2.6.0/docs/Creating_a_cluster.md>).

Boundary (ADR-0028): **hetzner-k3s owns the cluster + cloud resources only** — it stops at a working
kubeconfig (and installs Cilium + hcloud CCM + hcloud-csi). Argo CD owns everything in-cluster.

## Why k3s primary, Talos/OpenTofu alternative

| | **k3s (this dir, primary)** | **Talos + OpenTofu (`../terraform`)** |
|---|---|---|
| Tooling | single CLI + one YAML | `tofu` + community module |
| OS-image prereq | **none** — uses stock `ubuntu-24.04` | **must upload a Talos image first** (the wall we hit) |
| Batteries | Cilium, hcloud CCM, hcloud-csi installed by the tool | module installs Cilium + CCM |
| IaC purity | imperative CLI (idempotent, re-runnable) | declarative, state-tracked |
| Verdict | **fastest reliable proof, no prereq gap** | IaC-pure, but blocked on the image step |

Both prove the same thing (same appsets reconcile off-GKE). k3s wins on time-to-proof because it has no
image-upload prerequisite; Talos stays documented as the IaC-pure option for forks that want it.

## Prereqs (full chain — verified end-to-end)

1. **hetzner-k3s CLI v2.6.0** — `brew install vitobotta/tap/hetzner_k3s` (then `hetzner-k3s --version`
   to confirm 2.6.0), or grab the v2.6.0 binary from the
   [releases page](https://github.com/vitobotta/hetzner-k3s/releases/tag/v2.6.0).
2. **`kubectl`** and **`gcloud`** (for the token + the ESO secret).
3. **An SSH keypair** at `~/.ssh/id_ed25519[.pub]` (the paths in `cluster_config.yaml`). hetzner-k3s
   injects the public key into every node. Generate with `ssh-keygen -t ed25519` if absent, or point the
   config at an existing key. (No SSH key → Hetzner emails per-node root passwords; avoid that.)
4. **`HCLOUD_TOKEN`** — a Hetzner Cloud API token (Read & Write), stored in GSM as `hcloud-token`:
   ```sh
   export HCLOUD_TOKEN=$(gcloud secrets versions access latest --secret=hcloud-token --project ai-lab)
   ```
   `HCLOUD_TOKEN` **takes precedence over** `hetzner_token` in the config, so the file stays secret-free.
   This token is the **only** credential needed to create the cluster.

That is the complete prereq list — no image upload, no packer step, no pre-existing cluster.

## Cluster bring-up

```sh
cd infra/hetzner/k3s
export HCLOUD_TOKEN=$(gcloud secrets versions access latest --secret=hcloud-token --project ai-lab)
hetzner-k3s create --config cluster_config.yaml | tee create.log
```

`create` is idempotent — re-run on a stuck/timed-out run to resume. It writes `kubeconfig.hetzner` in
this directory. Point kubectl at it:

```sh
export KUBECONFIG=$PWD/kubeconfig.hetzner
kubectl get nodes        # 1x cpx32 master + 3x cpx42 workers, all Ready
```

## Substrate prerequisite: default LB zone on the hcloud CCM

The platform's public-edge gateways are `Service type=LoadBalancer` with **no** cloud-specific
annotations — kept substrate-agnostic on purpose (the same manifests run on GKE). The hcloud CCM,
however, refuses to create a Cloud LB unless it has a **default location or network zone**, failing
with `neither load-balancer.hetzner.cloud/location nor load-balancer.hetzner.cloud/network-zone set`.
That default is a **substrate prerequisite** (the same category as "a default StorageClass must
exist"), not product config — so it is set on the CCM, once, right after the cluster comes
up and before `make root` brings the gateways up:

```sh
kubectl -n kube-system set env deployment/hcloud-cloud-controller-manager \
  HCLOUD_LOAD_BALANCERS_NETWORK_ZONE=eu-central   # covers nbg1/fsn1/hel1; the cluster's zone
```

`make doctor` enforces this: it fails loudly if any `LoadBalancer` Service is stuck without an
external address, so a missing zone never silently leaves the gateway unreachable. (hetzner-k3s
v2.6.0 exposes no native hook to set CCM env — `cloud_controller_manager` only takes `enabled` +
`manifest_url`, which fetches over unauthenticated HTTP and so can't reference a private repo. The
Talos/OpenTofu path (`../terraform`) sets this declaratively via the CCM helm values instead.)

## Bootstrap → make root (the portability payoff)

With `KUBECONFIG` on the Hetzner cluster, the existing GitOps flow runs unchanged from the repo root:

```sh
make bootstrap                                   # install Argo CD on this kube-context
ARGOCD_REPO_PAT=$(gh auth token) make argocd-repo   # repo cred (private repo only)
# seed the off-GCP ESO secret — see "Secrets" below
make resolve-groups                              # clusters/<cluster>/groups.generated.yaml
make root PROFILE=serving                        # AppProject + per-layer ApplicationSets (CPU serving)
```

The **same** `catalog/appsets` reconcile here as on GKE — that *is* the proof. Argo installs
cert-manager, ESO, Kueue, KEDA, kube-prometheus-stack, KServe, vLLM (CPU), routing, etc. with no manifest
changes.

> `make root` reads `CLUSTER` (default `ai-dev`). If you want a distinct cluster dir, run with
> `CLUSTER=ai-dev-hetzner` consistently across `resolve-groups`/`root`; otherwise the existing `ai-dev`
> dir is reused (fine for a single throwaway proof).

## Secrets off-GCP: ESO is the swap point; GSM + static SA key

Identical to the Talos path — the `ClusterSecretStore` is backend-agnostic to *how* the cluster was
built. Set `secret_store_auth: sa-key` in `environments/<env>/config.yaml` and run
`make resolve-secret-store`: it renders `platform/external-secrets/config/clustersecretstore.yaml`
with SA-key auth (same `metadata.name` `secret-store` as the GKE default, so a cluster has exactly
one). It keeps **Google Secret Manager** as the backend, authenticated off-GCP by a **static
service-account key** (simpler to reproduce than WIF — no pool/provider/JWKS).

One-time operator setup (seed the SA-key Secret before `make root` so ExternalSecrets resolve):

```sh
PROJECT=ai-lab
gcloud iam service-accounts create eso-hetzner --project "$PROJECT"
gcloud projects add-iam-policy-binding "$PROJECT" \
  --member "serviceAccount:eso-hetzner@$PROJECT.iam.gserviceaccount.com" \
  --role roles/secretmanager.secretAccessor
gcloud iam service-accounts keys create sa-key.json \
  --iam-account "eso-hetzner@$PROJECT.iam.gserviceaccount.com"
kubectl create namespace external-secrets --dry-run=client -o yaml | kubectl apply -f -
kubectl -n external-secrets create secret generic secret-store-key --from-file=sa-key.json=sa-key.json
rm -f sa-key.json    # the key now lives only in the cluster Secret
```

The generated store (committed via `make resolve-secret-store`) syncs through Argo with the rest of
the platform — no manual `kubectl apply` of the store.

Pin ESO ≥ 2.6.0. To go fully off-GCP, swap the provider block in `scripts/resolve-secret-store.sh` (full detail in
`../terraform/README.md` and the file's header). GSM is still a GCP dependency; ESO is the portable
interface that a forker repoints.

## What differs from GKE (cloud-integration layer only)

| Concern | GKE | Hetzner (k3s) |
|---|---|---|
| LoadBalancer | GKE LB | **hcloud CCM Cloud LB** — a `Service type=LoadBalancer` (the gateway) provisions a Hetzner Cloud LB; annotate `load-balancer.hetzner.cloud/location` + `use-private-ip: "true"` |
| Storage | PD/Hyperdisk (RWO) + Filestore (RWX) | **hcloud-csi `hcloud-volumes` RWO** (Ceph-backed, 10Gi min), installed by the tool; **no RWX** → shared weights need self-hosted NFS/Longhorn |
| GPU | L4 pool, scale-to-zero | **None** → CPU serving; no `$0`-idle (you pay per box 24/7) |
| CNI / NetworkPolicy | Dataplane-V2 (Cilium) | **Cilium v1.17.2** (kube-proxy replaced) enforcing native `networking.k8s.io/v1` NetworkPolicy — parity, no CRD lock-in (ADR-0029 SR1) |
| Secrets auth | GKE Workload Identity | **static SA key** to the same GSM backend (above) |

Everything above the cloud-integration layer (cert-manager, KEDA, Kueue, vLLM, GIE/agentgateway,
LiteLLM, CNPG, kube-prometheus-stack) moves unchanged.

## Teardown

```sh
# protect_against_deletion: true in the config blocks delete — flip it first.
sed -i '' 's/^protect_against_deletion: true/protect_against_deletion: false/' cluster_config.yaml
hetzner-k3s delete --config cluster_config.yaml    # prompts for the cluster name to confirm
```

`delete` removes only what hetzner-k3s created (nodes, network, firewall, master/API LB). It does **not**
delete resources your apps created — the **gateway Cloud LB** (CCM), **PVs** (hcloud-csi volumes), and
any floating IPs/snapshots. Delete those in the Hetzner Console afterward, or — since this is a throwaway
in its own project — delete the whole project. Watch billing for a day for orphans.

## Config summary

`cluster_config.yaml`: 1× `cpx32` master (nbg1) + 3× `cpx42` workers (fixed pool, autoscaler off), Cilium
CNI, private network `10.0.0.0/16`, embedded etcd, `schedule_workloads_on_masters: true`. Tighten
`networking.allowed_networks.{ssh,api}` from `0.0.0.0/0` to your `/32` before a non-lab create.
