---
title: "Pending GPU workloads"
---

How to tell *why* a GPU Job isn't running, plus the gotchas hit standing up Kueue. A Job is
either **suspended by Kueue** (waiting on quota, working as intended) or **Pending at the
scheduler** (admitted but no GPU node). They look different and need different actions.

## Is it Kueue (quota) or the scheduler (capacity)?

```bash
kubectl get localqueue -A                 # PENDING vs ADMITTED counts per queue
kubectl get workloads -A                  # ADMITTED column: True = past Kueue
kubectl -n <ns> get workload <name> -o jsonpath='{.status.conditions}'
```

- **Workload not admitted** → Kueue is holding it. The condition message is explicit, e.g.
  `couldn't assign flavors to pod set main: insufficient unused quota for nvidia.com/gpu in
  flavor gpu-any, 1 more needed`. There is **no pod yet**: the Job is suspended. This is
  correct behaviour when another workload holds the single GPU's quota; it admits automatically
  when quota frees (or on preemption). Nothing to fix.
- **Workload admitted but the pod is Pending** → it's past Kueue; now it's a scheduling/capacity
  problem (GPU node provisioning, or `GCE out of resources`). See `docs/public/guides/vllm-serving.md`
  §2 (GPU-agnostic scheduling + T4 fallback).

A Job that isn't governed by Kueue at all (no `kueue.x-k8s.io/queue-name` label) is never
suspended: `manageJobsWithoutQueueName` is `false`, so check the label first.

## 1. ClusterQueue / ResourceFlavor fail to apply: "no endpoints available" for the webhook

**Symptom:** on first sync the `ClusterQueue` and `ResourceFlavor` error with
`failed calling webhook "mclusterqueue.kb.io": ... no endpoints available for service
"kueue-webhook-service"`. (LocalQueues/WorkloadPriorityClasses may apply fine.)

**Cause:** a sync-wave ordering race: the queue config (wave 3) was applied before the Kueue
controller's webhook pod had endpoints. Kueue uses **internal cert management** (no
cert-manager), and the webhook only serves once the controller is Ready.

**Fix:** none needed long-term: Argo CD `selfHeal` retries and succeeds once the controller is
up. To force it: `kubectl -n argocd annotate application kueue-config argocd.argoproj.io/refresh=hard --overwrite`.
Confirm the webhook is ready first:
```bash
kubectl -n kueue-system rollout status deploy/kueue-controller-manager
kubectl -n kueue-system get endpoints kueue-webhook-service
```

## 2. ClusterQueue stuck OutOfSync forever (Argo drift)

**Symptom:** `kueue-config` never reaches Synced; only `ClusterQueue/gpu-cq` is OutOfSync.

**Cause:** the ClusterQueue **mutating webhook fills defaults** not present in git:
`queueingStrategy: BestEffortFIFO`, `stopPolicy: None`,
`flavorFungibility: {whenCanBorrow: MayStopSearch, whenCanPreempt: TryNextFlavor}`,
`preemption.borrowWithinCohort.policy: Never`. Argo then sees live ≠ desired every reconcile.

**Fix:** set those fields **explicitly** in the manifest so git matches the mutated object
(done in `platform/kueue-config/clusterqueue.yaml`). Preferable to `ignoreDifferences`: the
config stays self-documenting.

## 3. ClusterQueue Active=False

```bash
kubectl get clusterqueue gpu-cq -o jsonpath='{.status.conditions[?(@.type=="Active")]}'
```
Common reasons: a `flavors[].name` references a `ResourceFlavor` that doesn't exist, or
`coveredResources` omits a resource the flavor lists. Fix the reference; it goes Active within
seconds.

## 4. Kueue's Job/Pod webhooks block unrelated workloads (CNPG initdb wedges)

**Symptom:** an unrelated controller's Job fails to create with
`failed calling webhook "mjob.kb.io": ... no endpoints available for service "kueue-webhook-service"`.
The clearest victim is CloudNativePG: its `litellm-pg-1-initdb` Job is rejected, the Postgres primary
is never created (`Setting up primary` forever), and the LiteLLM migration blocks behind it.

**Cause:** Kueue's `batch/v1` Job and `v1` Pod admission webhooks ship `failurePolicy: Fail` and,
unscoped, match **every** Job and Pod in the cluster. While the Kueue controller is still starting
(no webhook endpoints yet), any Job or Pod creation fails closed. CNPG creates its initdb Job once and
does not retry, so it wedges hard. Upstream tracks the fail-closed-by-default behaviour as
[kubernetes-sigs/kueue#5244](https://github.com/kubernetes-sigs/kueue/issues/5244).

**Fix:** the platform renders Kueue through a kustomize wrapper (`platform/kueue/kustomization.yaml`)
that scopes the four cluster-universal webhooks (`mjob`/`vjob`/`mpod`/`vpod`) to namespaces labelled
`llm-platform/kueue-managed: "true"`. Infra namespaces (`litellm`, `serving`) never reach Kueue and
cannot be blocked by it; tenant namespaces opt in with that one label. If a cluster is already wedged
from before this fix, delete the CNPG Cluster so the operator recreates the initdb Job once the webhook
is healthy: `kubectl -n litellm delete cluster litellm-pg` (Argo `selfHeal` recreates it).

## Verify admission + preemption (the demo)

```bash
kubectl apply -f workloads/kueue-demo/job-team-a.yaml   # admitted, holds the GPU
kubectl apply -f workloads/kueue-demo/job-team-b.yaml   # suspended on quota
kubectl get workloads -A                                # team-a ADMITTED=True, team-b pending
```
Kueue injects the `nvidia.com/gpu` toleration onto team-a's pod from the `gpu-any` flavor (the
Job spec carries none), and the autoscaler brings up whichever GPU pool has capacity. Set
team-b's `kueue.x-k8s.io/priority-class` to `high-priority` to preempt team-a. Clean up with
`kubectl -n team-a delete job gpu-job-a` / `kubectl -n team-b delete job gpu-job-b`.
