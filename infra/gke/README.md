# infra/gke

GKE cloud substrate. Everything above the cluster is GitOps.

- `terraform/` — OpenTofu root for APIs, GKE, CPU/GPU node pools, Workload Identity IAM, node
  service account, and Artifact Registry modelcar repo. See
  [ADR-0028](../../docs/public/decisions/0028-iac-cloud-substrate.md).

Prereq: `NVIDIA_L4_GPUS` (regional) and `GPUS_ALL_REGIONS` (global) quota >= 1; on-demand nodes
also need regional `CPUs` headroom. Request increases if any are 0 (see
`docs/public/guides/gpu-debugging.md`).
