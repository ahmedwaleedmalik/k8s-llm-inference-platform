# kueue-demo

Demonstrates Kueue **GPU quota + admission** on a single-GPU cluster: two tenants (`team-a`,
`team-b`) submit GPU Jobs to LocalQueues that share one ClusterQueue with `nvidia.com/gpu`
quota of **1**. Run manually (not GitOps-synced).

Prereq: the `kueue` and `kueue-config` Argo apps are Synced/Healthy.

## Admission + queueing (the core demo)

```sh
kubectl apply -f workloads/kueue-demo/job-team-a.yaml   # admitted → holds the 1 GPU
kubectl apply -f workloads/kueue-demo/job-team-b.yaml   # suspended → waits on quota

# team-a's Workload is Admitted; team-b's is Pending on quota:
kubectl -n team-a get workloads
kubectl -n team-b get workloads
kubectl get clusterqueue gpu-cq -o jsonpath='{.status.flavorsReservation}{"\n"}'
```

`team-b`'s Workload stays `Pending` with a message like *"couldn't assign flavors to pod set
… insufficient quota for nvidia.com/gpu"*. When `team-a` finishes (or is deleted), Kueue
admits `team-b` automatically. (`gpu-job-a` sleeps 600s so there's time to observe.)

A GPU node provisions for the admitted job; `make vllm-down`-style teardown: delete the Jobs,
the node scales back to 0.

## Preemption (priority variant)

Make `team-b` urgent and watch it reclaim the GPU from the running low-priority `team-a`:

```sh
kubectl apply -f workloads/kueue-demo/job-team-a.yaml
# edit job-team-b.yaml: kueue.x-k8s.io/priority-class: high-priority, then:
kubectl apply -f workloads/kueue-demo/job-team-b.yaml
```

Kueue evicts `team-a` (re-suspends its Workload) and admits `team-b`, because `gpu-cq` sets
`preemption.withinClusterQueue: LowerPriority`.

## Cleanup

```sh
kubectl -n team-a delete job gpu-job-a --ignore-not-found
kubectl -n team-b delete job gpu-job-b --ignore-not-found
```
