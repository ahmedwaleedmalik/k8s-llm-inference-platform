---
title: "Validation and teardown"
---

Two jobs: (A) confirm a deployment is actually healthy before you rely on it, and (B) tear it
down **in an order that leaves no paid GCP resource behind**. The default cost posture is already
"$0 idle" (GPU pool scales to 0, serving apps are manual-sync, see `staged-bring-up.md`), so most
sessions only need the [cost-stop fast path](#b-cost-stop-fast-path). Full teardown is for when
you're done with the cluster entirely.

Cluster facts (from `environments/ai-dev/config.yaml` + `infra/gke/terraform/terraform.tfvars`):
project `<your-project>`, cluster `ai-dev`, location `us-central1-a`. Export them once so the
blocks below paste clean:

```sh
export PROJECT=<your-project> CLUSTER=ai-dev LOCATION=us-central1-a
```

---

## ⚠️ Cost footgun: four things that survive a naive `kubectl delete` / cluster delete

A deleted cluster (or `kubectl delete ns ...`) does **not** reclaim these. They keep billing on
their own line items until you delete them explicitly. Audit for all four at the end (§C.7):

| Survivor | Created by | Reclaim with |
|---|---|---|
| **External IPs + forwarding rules** | the agentgateway data-plane LB behind each `Gateway` (`kserve-ingress-gateway`, `inference-gateway`) | delete the `Gateway` objects **before** the cluster (§C.3) |
| **Persistent disks (PDs)** | the model-cache PVCs `vllm-model-cache` (serving), `kserve-model-cache` (kserve), bound on the GKE default SC `standard-rwo` | delete the PVCs, then verify no orphan disks (§C.4) |
| **GPU node pool** | OpenTofu (`gpu-l4`, optional extra pools) | scale to 0 (fast) or delete via OpenTofu (§B / §C.2) |
| **Secret Manager secrets + GSA** | secret values seeded manually; ESO GSA/IAM from OpenTofu | optional cleanup §C.6 (free at rest, but delete if abandoning the project) |

The classic bill: you delete the cluster, assume you're done, and a **forwarding rule + reserved
external IP** from the gateway LB keeps charging for weeks. Delete Gateways before the cluster.

---

## A. Validation checklist (is it actually healthy?)

Run these before trusting a deployment. Concrete pass conditions in each step.

**1. Argo apps Synced + Healthy.** Platform apps are auto-sync; serving/demo are manual.

```sh
argocd app list                                    # STATUS=Synced, HEALTH=Healthy
argocd app list -o name | xargs -n1 argocd app wait --health --timeout 600
kubectl -n argocd get applications                 # alt if argocd CLI not logged in
```

Expect manual-sync apps (`raw-vllm`, `kserve-demo`, `inference-demo`) to show their workload state
only after an explicit `argocd app sync`.

**2. GPU node present *only when scaled up*.** With serving at `replicas:0` there should be **no**
GPU node (that's the $0-idle state, not a fault). After `make vllm-up`:

```sh
kubectl get nodes -L cloud.google.com/gke-accelerator    # an nvidia-l4 (or -t4) node appears
kubectl -n serving get pods -l app.kubernetes.io/name=raw-vllm   # Running, not Pending
make vllm-down   # scale back to 0 → node drains and the pool returns to 0 (see GPU debugging runbook)
```

If the pod is stuck `Pending`, see `pending-gpu-workloads.md` / `gpu-debugging.md` (quota, taints).

**3. vLLM smoke returns 200.** Authenticated OpenAI chat round-trip (after `make vllm-up`):

```sh
make vllm-smoke    # scripts/smoke-chat.sh → /v1/chat/completions, expect HTTP 200 + a completion
```

KServe ISVC variant (CPU, no GPU node needed):

```sh
kubectl -n kserve get isvc qwen-cpu                # READY=True
GW=$(kubectl -n kserve get gateway kserve-ingress-gateway -o jsonpath='{.status.addresses[0].value}')
curl -s -H "Host: qwen-cpu-kserve.example.com" http://$GW/v1/models   # JSON model list
```

**4. ServiceMonitors scraping.** The `raw-vllm` ServiceMonitor (ns serving) and DCGM metrics feed
the in-cluster Prometheus.

```sh
kubectl -n serving get servicemonitor raw-vllm
# Prometheus targets UP (port-forward Prometheus, then check /api/v1/targets), or in Grafana:
# vLLM series only exist while the pod runs (scaled to 0 → no scrape; that's expected).
```

**5. No stuck PVCs / pending volumes.** Every PVC should be `Bound`, none `Pending`/`Terminating`.

```sh
kubectl get pvc -A     # vllm-model-cache (serving), kserve-model-cache (kserve) → Bound
```

---

## B. Cost-stop fast path

Keeps the cluster + GitOps intact, drops GPU spend to ~$0. This is the everyday action.

```sh
make vllm-down                                      # scale raw-vllm to 0 → releases the L4 node ($0 idle)
```

`make vllm-down` is the fastest "stop paying" lever: it scales `deploy/raw-vllm` to 0, the GPU pod
terminates, and the autoscaler returns `gpu-l4` to 0 nodes (the pool's `--min-nodes=0`). Argo won't
revert it (`ignoreDifferences` on `/spec/replicas`).

Pause the KServe CPU predictor too, if it's running:

```sh
kubectl -n kserve annotate isvc qwen-cpu serving.kserve.io/stop=true --overwrite   # resume: stop-
```

Tear down the demo workloads if up (sim backends are $0-GPU but still consume CPU/RAM):

```sh
argocd app delete inference-demo --yes              # or just leave manual apps unsynced
argocd app delete kserve-demo --yes
```

After this: GPU node = 0, only the always-on control plane + `default-pool` cost remains. PVCs
(PDs) persist: cheap, and they keep model caches warm. To reclaim those too, do a full teardown.

> Cheaper still without losing GitOps: scaling `default-pool` to 0 is **not** safe here. Argo,
> the agentgateway/KServe controllers, ESO and Prometheus run there. To go fully $0, do §C.

---

## C. Full teardown (ordered to avoid orphans)

Order matters: workloads → GPU pool → **LBs/Gateways → PVCs → cluster** → optional secrets →
audit. Deleting the cluster first strands forwarding rules and disks (the footgun above).

### C.1 Scale workloads to 0 / delete serving apps

```sh
make vllm-down
kubectl -n kserve annotate isvc qwen-cpu serving.kserve.io/stop=true --overwrite
argocd app delete raw-vllm kserve-demo inference-demo --yes    # remove the manual-sync workloads
```

**Narrowing a profile / removing a whole layer** (deployment profiles):
profiles are additive: applying a narrower `PROFILE` does **not** prune wider layers. To remove a
layer, delete its per-layer ApplicationSet (its group-roots + child apps prune with it):

```sh
kubectl delete -f clusters/ai-dev/appsets/demos.yaml        # drop the sim/demo layer
kubectl delete -f clusters/ai-dev/appsets/llm-gateway.yaml  # drop LiteLLM + CNPG, then routing, serving…
```

Delete appsets in reverse order (`demos → llm-gateway → routing → serving → platform`); keep `platform`
last (Argo CD self-manages there). For a full cluster teardown, continue with C.2-C.7 below.

### C.2 Delete the GPU node pool

Scale-to-0 already costs ~$0, so for a short pause just `make vllm-down`. For a full
OpenTofu-created cluster teardown, delete Gateways/PVCs first, then let `make tf-destroy` remove the
pool with the rest of the substrate in C.5. If you need to remove only the GPU pool manually:

```sh
gcloud container node-pools delete gpu-l4 \
  --cluster="$CLUSTER" --location="$LOCATION" --project="$PROJECT"
# If the T4 fallback pool was ever created (POOL=gpu-t4 in the script):
gcloud container node-pools delete gpu-t4 \
  --cluster="$CLUSTER" --location="$LOCATION" --project="$PROJECT" 2>/dev/null || true
```

> Scale-to-0 vs delete: the pool at 0 nodes has **no compute cost**, so keep it if you'll serve
> again soon (avoids re-running the create script + re-driver-install). Delete it only when
> tearing the whole cluster down, or if you're deleting the cluster anyway (which removes it).

### C.3 Delete LoadBalancer Services / Gateways **BEFORE the cluster**

This is the bill footgun. Each agentgateway-backed `Gateway` provisions a data-plane LB → a GCP
**forwarding rule + external IP** that **outlives a deleted cluster**. Delete the Gateways (and let
the controller deprovision the LB) while the cluster + controller still exist:

```sh
kubectl -n kserve   delete gateway kserve-ingress-gateway --ignore-not-found
kubectl -n inference delete gateway inference-gateway     --ignore-not-found   # routing demo
```

Then confirm the controller actually released the cloud LB before moving on:

```sh
gcloud compute forwarding-rules list --project="$PROJECT"   # expect: no rows tied to these gateways
gcloud compute addresses list       --project="$PROJECT"    # expect: no leftover reserved external IP
```

If a forwarding rule / address lingers (controller gone, or LB orphaned), delete it directly:

```sh
gcloud compute forwarding-rules delete <NAME> --region="${LOCATION%-*}" --project="$PROJECT"
gcloud compute addresses        delete <NAME> --region="${LOCATION%-*}" --project="$PROJECT"
```

> No `Service type: LoadBalancer` exists in the manifests; the only LBs are the two agentgateway
> data-plane Services the controller creates per Gateway. They live in the gateway's namespace; find
> them with `kubectl get svc -A | grep -i loadbalancer` if you need the exact name.

### C.4 Delete PVCs and confirm the backing PDs are gone

On GKE these PVCs each bind a GCE PD via the default SC `standard-rwo`. Deleting the namespace/PVC
should delete the PD (reclaimPolicy `Delete` on `standard-rwo`), but **verify**: a `Retain`/stuck PV
strands the disk.

```sh
kubectl -n serving delete pvc vllm-model-cache  --ignore-not-found
kubectl -n kserve  delete pvc kserve-model-cache --ignore-not-found
kubectl get pvc -A                                          # expect: none of ours remain
kubectl get pv | grep -iE 'serving|kserve'                  # expect: no Released/stuck PVs
```

Then confirm at the cloud layer that no PD survived:

```sh
gcloud compute disks list --project="$PROJECT" \
  --filter="name~pvc OR name~ai-dev"                        # expect: no rows for the model caches
# delete any orphan directly:
gcloud compute disks delete <DISK_NAME> --zone="$LOCATION" --project="$PROJECT"
```

### C.5 Delete the cluster / OpenTofu substrate

Only after Gateways/LBs and PVCs/PDs are confirmed gone (so nothing is stranded):

```sh
make tf-destroy
```

This removes the control plane, `default-pool`, GPU pool, node service account/IAM, Artifact Registry
repo, and ESO IAM for an OpenTofu-created cluster.

For an older script-created cluster:

```sh
gcloud container clusters delete "$CLUSTER" \
  --location="$LOCATION" --project="$PROJECT"
```

This removes the control plane, `default-pool`, and any remaining node pools.

### C.6 Optional: remove Secret Manager values / legacy GSA

Secrets at rest in Secret Manager are effectively free, so keep them if you'll redeploy. Remove
them only when abandoning the project. OpenTofu removes the ESO GSA/IAM in C.5; the GSA commands below
are only for older script-created clusters.

```sh
GSA=external-secrets@${PROJECT}.iam.gserviceaccount.com

# Secret Manager entries (referenced by the ExternalSecrets in serving/raw-vllm + serving/kserve)
gcloud secrets delete vllm-api-key --project="$PROJECT"
gcloud secrets delete hf-token     --project="$PROJECT"

# Legacy script-created clusters only: Workload Identity binding + the GSA.
gcloud iam service-accounts remove-iam-policy-binding "$GSA" --project="$PROJECT" \
  --role="roles/iam.workloadIdentityUser" \
  --member="serviceAccount:${PROJECT}.svc.id.goog[external-secrets/external-secrets]"
gcloud projects remove-iam-policy-binding "$PROJECT" \
  --member="serviceAccount:${GSA}" --role="roles/secretmanager.secretAccessor"
gcloud iam service-accounts delete "$GSA" --project="$PROJECT"
```

### C.7 Final audit: confirm nothing paid is left

Run all four. Every one should return **no rows tied to `ai-dev`** (other unrelated project
resources may legitimately appear):

```sh
gcloud compute disks            list --project="$PROJECT"   # PVC-backed PDs gone
gcloud compute forwarding-rules list --project="$PROJECT"   # gateway LB forwarding rules gone
gcloud compute addresses        list --project="$PROJECT"   # reserved external IPs gone
gcloud container node-pools     list --cluster="$CLUSTER" --location="$LOCATION" --project="$PROJECT" 2>/dev/null \
  || echo "cluster deleted, no node pools"
```

If all four are clean, the meter is at $0 for this platform.

---

## D. Validate the OpenTofu substrate: two paths

The GKE substrate is now OpenTofu-managed, but the live `ai-dev`
cluster was created by the old shell scripts: **OpenTofu has no state for it and does not track it.** So the
first real `tofu apply` is unproven. Pick a path by intent.

### D.1 Parallel substrate validation (recommended, zero downtime)

Stand up a **second, throwaway** cluster from OpenTofu *next to* the running one, in the same project, and
prove the IaC end-to-end without touching production. This is the safe way to validate the substrate while real work
keeps running on `ai-dev`.

**Use isolated resource names: do NOT reuse/import the live ESO GSA or Artifact Registry repo.** Those are
project-level singletons the live cluster depends on; if the throwaway state owned them, `tofu destroy` would
delete them out from under production. Isolated names cost one var-file and let OpenTofu create *and* cleanly
destroy a parallel GSA / AR repo / node SA. (The `secretAccessor` grant rides along, so ESO still works on the
validation cluster.)

```sh
cd infra/gke/terraform

cat > validation.tfvars <<'EOF'   # throwaway; keep untracked (git-ignored or rm after)
project_id   = "<your-project>"
cluster_name = "ai-dev-tf"
region       = "us-central1"
location     = "us-central1-a"

node_service_account_id             = "gke-aidevtf-nodes"
external_secrets_service_account_id = "eso-aidevtf"
modelcar_repository_id              = "models-aidevtf"

gpu_min_node_count = 0
gpu_max_node_count = 1
EOF

# Call tofu directly (NOT make / scripts/tofu.sh, which injects ai-dev's name from config.yaml).
# Use a separate workspace so this state never mixes with the real cluster's future state.
tofu init
tofu workspace new validation
tofu apply -var-file=validation.tfvars        # ~ creates cluster ai-dev-tf + parallel substrate
```

Validate, then tear the throwaway down completely:

```sh
gcloud container clusters get-credentials ai-dev-tf --location us-central1-a --project <your-project>
kubectl get nodes -L cloud.google.com/gke-accelerator     # platform pool up; GPU pool at 0
gcloud artifact-registry repositories list --project <your-project> | grep models-aidevtf
make doctor PROFILE=platform                              # local config + live prereqs (current context = ai-dev-tf)

tofu destroy -var-file=validation.tfvars                 # removes ONLY the -aidevtf resources
tofu workspace select default && tofu workspace delete validation
rm validation.tfvars
```

Notes / gotchas:
- **Shared GPU quota.** Both clusters draw the same regional L4 quota (1). Keep the validation GPU pool at
  `min 0` and don't `make vllm-up` on it while `ai-dev` is serving on GPU, or the second hits a stockout.
- **Optional full profile bring-up** (deeper proof): `make bootstrap && make argocd-repo && make root
  PROFILE=platform` with `./kubeconfig` pointed at the `ai-dev-tf` cluster. ESO's K8s SA annotation comes from git and points at the
  **live** `external-secrets@…` GSA, so via Workload Identity the validation cluster reads secrets through the
  live GSA; the tf-created `eso-aidevtf` GSA is created-and-destroyed purely as substrate proof. Fine for
  validation; don't promote this cluster.
- Restore the dedicated kubeconfig afterwards: `gcloud container clusters get-credentials ai-dev --location
  us-central1-a --project <your-project> --kubeconfig=$PWD/kubeconfig`.

### D.2 Retire `ai-dev` and rebuild from OpenTofu (the real cutover)

Only when you actually want the gcloud-created cluster gone and the OpenTofu one to become live. **This is
destructive** and the next `tofu apply` becomes your production cluster.

1. **Back up anything not in git / Terraform / Secret Manager first.** The one piece of live state that is in
   *none* of those is the **LiteLLM Postgres** (`litellm-pg`, CNPG `instances: 1`, **no backups**): it holds
   the virtual keys and spend history. A teardown destroys its PD permanently. If that data matters, dump it:

   ```sh
   kubectl -n litellm exec -it litellm-pg-1 -- pg_dump -U postgres litellm > litellm-$(date +%F).sql
   ```

   (Today's keys/spend are demo/validation data and are re-mintable; skip the dump if you don't care.)
2. **Ordered teardown of `ai-dev`** via §C (Gateways → PVCs/PDs → cluster). The live cluster is script-created,
   so delete it with the §C.5 `gcloud container clusters delete` path, **not** `make tf-destroy` (empty state).
   Run the §C.7 audit, confirm no stranded forwarding-rules / IPs / disks.
3. **First real apply**: this creates the live cluster from IaC:

   ```sh
   make tf-init && make tf-plan && make tf-apply
   make bootstrap && make argocd-repo
   make root PROFILE=platform && make doctor PROFILE=platform
   # then serving / llm-gateway / full per the per-profile bring-up matrix
   ```

   Secrets in Secret Manager are retained (free at rest); ESO re-materializes them, so you do **not** re-seed
   them. Note the rebuilt cluster's nodes use the dedicated node SA (`gke-ai-dev-nodes`), not the old default
   compute SA, intended (least-privilege), but node identity is not byte-identical to the retired cluster.
