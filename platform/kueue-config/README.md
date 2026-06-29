# kueue-config

The Kueue queue topology: what quota exists and who can use it.

| Object | Role |
|---|---|
| `ResourceFlavor` `gpu-any` | A GPU-agnostic flavor: no nodeLabels, carries the `nvidia.com/gpu` toleration Kueue injects onto admitted pods so they land on the tainted GPU pools (`gpu-l4`/`gpu-t4`). |
| `ClusterQueue` `gpu-cq` | The shared quota pool: `nvidia.com/gpu = 1` (the cluster's one physical GPU). Preemption `withinClusterQueue: LowerPriority` (no cohort — single queue; v1beta2 moved cohorts to their own CRD). |
| `LocalQueue` `team-a-gpu`, `team-b-gpu` | Namespaced handles (one per tenant) onto `gpu-cq`. Jobs target one via the `kueue.x-k8s.io/queue-name` label. |
| `WorkloadPriorityClass` `low-`/`high-priority` | Kueue admission/preemption order (label `kueue.x-k8s.io/priority-class`). |
| Namespaces `team-a`, `team-b` | The two competing tenants. |

## Why one agnostic flavor (not l4 + t4)

`GPUS_ALL_REGIONS = 1` means exactly one physical GPU exists, so `nominalQuota: 1` over a
single flavor is the honest model, and it makes the demo crisp: the second job waits *in
Kueue*, not at the scheduler. **Flavor fungibility** (a ClusterQueue listing `l4` then `t4`
flavors so a job falls back across pools) is the natural design once the GPU budget exceeds 1;
today that l4→t4 fallback already happens one layer down, in the cluster autoscaler (the GPU
pods pin no accelerator, see `infra/gke`). See [ADR-0002](../../docs/public/decisions/0002-kueue-quota-admission.md).

Demo: [`workloads/kueue-demo`](../../workloads/kueue-demo/).
