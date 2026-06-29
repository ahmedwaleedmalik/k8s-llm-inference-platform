---
title: "ADR-0028: IaC owns the cloud substrate, Argo CD owns in-cluster lifecycle"
---

**Status:** Accepted
**Date:** 2026-06-20

## Context

The GKE lab substrate was created by shell scripts (`infra/gke/create-cluster.sh`,
`infra/gke/add-gpu-nodepool.sh`) plus manual IAM and Artifact Registry commands. That works, but it
leaves a forker guessing at exact cluster flags, Workload Identity setup, GPU pool shape,
node IAM, and modelcar registry prerequisites.

This is the same forkability gap deployment profiles solved for Argo profiles, but one layer lower.

## Decision

Adopt **OpenTofu** for the GCP cloud substrate in `infra/gke/terraform/`.

**Ownership boundary:**

- **OpenTofu owns GCP resources only:** APIs, GKE cluster, CPU/GPU node pools, Workload Identity GSA +
  IAM binding, node service account, Artifact Registry repo, and Artifact Registry pull IAM.
- **Argo CD owns in-cluster resources:** CRDs/controllers, Kueue, KEDA, ESO, Prometheus/Grafana,
  KServe, vLLM, routing, LiteLLM, dashboards, namespaces, queues, and workloads.
- **Secret values never enter tfvars or state.** Terraform creates IAM; operators seed secret values
  manually in Secret Manager per the public secret contract.

State defaults to **local** for fork simplicity. A documented optional GCS backend exists for shared/team
state, but the bucket is bootstrapped out-of-band to avoid a circular dependency.

Provider pin: `hashicorp/google` **7.37.0** (official Terraform Registry, published 2026-06-16).

## Consequences

- A forker can reproduce the GKE substrate with `make tf-init && make tf-apply`, then bootstrap Argo and
  apply deployment profiles.
- The old shell scripts remain as readable compatibility references, but docs point to OpenTofu first.
- The modelcar path is no longer half-manual: the Artifact Registry Docker repo and node pull IAM are in
  IaC; image build/push still happens outside Terraform.
- `make config-check`, `make doctor`, `make wait`, and `make smoke` provide executable gates around
  config drift and profile bring-up.
- Live per-profile validation still requires paid cloud access: `tofu apply` fresh project → `make root`
  for each profile → `make wait`/`make smoke`.

Relates to [ADR-0027](/decisions/0027-deployment-profiles) (deployment profiles), [ADR-0011](/decisions/0011-secrets-and-config-strategy) (secrets), and [ADR-0016](/decisions/0016-model-delivery)
(modelcar delivery).
