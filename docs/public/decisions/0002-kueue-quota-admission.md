---
title: "ADR-0002: Kueue for GPU quota and admission"
---

**Status:** Accepted
**Date:** 2026-06-15

## Context

GPUs are the scarce resource: this cluster runs **one** GPU at a time
(`GPUS_ALL_REGIONS = 1`). Multiple workloads (and, conceptually, multiple teams) will want it.
We need to ration it fairly: admit work when capacity is free, **queue** it when not, and let
urgent work preempt best-effort work, without each submitter busy-waiting or the scheduler
thrashing.

This is an **admission/queueing** problem, not an autoscaling one. It must not be confused with:

- **HPA / KEDA**: scale replicas of a service on load.
- **Cluster Autoscaler / Karpenter**: add/remove nodes.
- **Gateway API Inference Extension**: route a request to the best replica.

Admission decides *whether a job may start at all, given a quota*; the autoscalers then react to
the pods it admits. Core Kubernetes alone can cap and prioritise but cannot queue.

## Options

1. **Plain `ResourceQuota` + `PriorityClass` + scheduler preemption.** Hard per-namespace caps
   and priority preemption with zero add-ons. But over-quota pods are **rejected, not queued**;
   there is no borrowing, no fair-sharing, no cohort, no "wait your turn." Operationally weak for
   contended GPUs.
2. **Volcano.** A *replacement* batch scheduler (ex `kube-batch`) with strong **gang
   scheduling**: all-or-nothing placement for multi-node distributed training/HPC. Powerful, but
   it supplants the default scheduler and is heavier than this single-GPU, single-node need.
3. **Kueue.** A quota/admission layer that sits **on top of** the default scheduler: it suspends
   an opted-in Job until its ClusterQueue has free quota, then un-suspends it. Provides nominal
   quota, borrowing within a **cohort**, fair-sharing, **preemption**, and **flavor fungibility**.
   A `kubernetes-sigs` project; integrates with Job, JobSet, Kubeflow, Ray.

(Also surveyed: **YuniKorn** (hierarchical queues, strongest for Spark/data) and **Run:ai**
(commercial/NVIDIA, fractional-GPU). Neither fits a small self-hosted OSS GPU platform better than
Kueue here.)

## Decision

Use **Kueue** (`v0.18.1`, OCI Helm chart) for GPU quota and admission.

- One **ResourceFlavor** `gpu-any` (no nodeLabels; carries the `nvidia.com/gpu` toleration Kueue
  injects on admission) and one **ClusterQueue** `gpu-cq` with `nvidia.com/gpu` nominal quota of
  **1**, the real physical capacity. Tenant namespaces `team-a`/`team-b` reach it through
  namespaced **LocalQueues**. Two **WorkloadPriorityClasses** drive preemption.
- Manifests are `kueue.x-k8s.io/**v1beta2**` (the served storage version in 0.18; v1beta1 is
  deprecated).
- `manageJobsWithoutQueueName: false`: Kueue governs **only** Jobs that opt in via the
  `kueue.x-k8s.io/queue-name` label, so the serving stack and system workloads are untouched.

### On flavor fungibility (deliberately deferred)

The instructive design (list `l4` then `t4` flavors so a job falls back across pools) needs a
GPU budget **> 1** to be meaningful (per-flavor quota would otherwise let Kueue admit more jobs
than there are GPUs, pushing the contention down to the scheduler and muddying the queueing
story). With one physical GPU, a single agnostic flavor with `nominalQuota: 1` is the honest
model; the l4→t4 fallback already exists one layer down, in the autoscaler (the GPU pods pin no
accelerator, ADR/infra). Revisit when the GPU budget grows.

## Consequences

- A second GPU job waits **in Kueue** (`Workload` Pending on quota), not as a failed pod,
  demonstrated in `workloads/kueue-demo`. A high-priority Workload preempts a running
  low-priority one.
- Kueue is the **batch/offline** admission layer. The always-on vLLM serving Deployment is **not**
  a natural Kueue object (it never completes); per-request serving scale/overload is a different
  layer (HPA/KEDA + inference-aware routing), not this ADR.
- Adds one controller (`kueue-system`) with internal cert management, no cert-manager dependency.
- Kueue's `batch/v1` Job and `v1` Pod admission webhooks ship `failurePolicy: Fail` and, unscoped,
  intercept every Job and Pod in the cluster, turning a not-yet-ready Kueue into a hard gate on all
  Job/Pod creation. During bring-up the CloudNativePG `litellm-pg` initdb Job raced the webhook, was
  rejected, and CNPG wedged (one-shot, no retry). Since admission is opt-in, the chart is rendered
  through a kustomize wrapper (`platform/kueue/kustomization.yaml`) that scopes those four webhooks
  to namespaces labelled `llm-platform/kueue-managed: "true"`. Infra namespaces (`litellm`,
  `serving`) never reach Kueue and cannot be blocked by it; tenant namespaces opt in with that one
  label, which is also what the require-kueue-queue-name policy gates on.
