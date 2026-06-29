# kueue

[Kueue](https://kueue.sigs.k8s.io/) provides job-level **quota and admission** for scarce resources
(here, the GPU). Kueue suspends a Job until its queue has free quota, then admits it; the next
job waits *in Kueue* rather than failing or thrashing the scheduler.

Kueue is not an autoscaler. It does not scale replicas (HPA/KEDA) or nodes
(Cluster Autoscaler/Karpenter); it gates *admission*. Admitted pods going Pending is what
*triggers* the node autoscaler. Its home is batch/offline work (fine-tuning, evals, batch
inference); for an always-on serving Deployment it is a forced fit. See
[ADR-0002](../../docs/public/decisions/0002-kueue-quota-admission.md).

- Installed from the OCI Helm chart `registry.k8s.io/kueue/charts/kueue`, pinned `0.18.1`
  (`clusters/ai-dev/catalog/platform-core/kueue.yaml`). Internal cert management; no cert-manager dependency.
- Rendered through a kustomize wrapper (`kustomization.yaml`, needs `kustomize.buildOptions: --enable-helm`)
  that scopes Kueue's fail-closed `batch/v1` Job and `v1` Pod admission webhooks to namespaces labelled
  `llm-platform/kueue-managed: "true"`. Unscoped, those webhooks intercept every Job/Pod cluster-wide, so a
  not-yet-ready Kueue blocks unrelated workloads (e.g. CloudNativePG's `litellm-pg` initdb Job, wedging CNPG).
  Tenant namespaces opt in with that one label; infra namespaces stay clear of Kueue entirely.
- `manageJobsWithoutQueueName` stays **false**: Kueue only governs Jobs that opt in via the
  `kueue.x-k8s.io/queue-name` label, so unrelated workloads are never suspended.
- Queue topology (ResourceFlavor / ClusterQueue / LocalQueues / WorkloadPriorityClasses) lives
  in [`platform/kueue-config`](../kueue-config/); a worked demo is in `workloads/kueue-demo`.

CRDs are served at **`kueue.x-k8s.io/v1beta2`** in 0.18 (v1beta1 is deprecated). Write queue
manifests against v1beta2.
