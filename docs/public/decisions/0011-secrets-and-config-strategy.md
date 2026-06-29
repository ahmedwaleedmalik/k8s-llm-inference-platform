---
title: "ADR-0011: Secrets and config strategy"
---

**Status:** Accepted
**Date:** 2026-06-13

## Context

This is a public GitOps repo: anyone can read it, and Argo CD reconciles the cluster from it.
No real secret value may ever reach git. We also want forkers to replace secrets and domains
easily and declaratively. Constraints: cluster is GKE-first; portability across providers is a goal; the Argo CD
repo credential is a chicken-and-egg bootstrap secret (needed before any secrets operator exists).

## Decision

Three lanes, by data type:

1. **Runtime secrets → External Secrets Operator (ESO) + GCP Secret Manager via Workload Identity.**
   Values live only in the backend; git holds `ExternalSecret` references. ESO authenticates with
   no stored credential (IAM only). The `ClusterSecretStore` is the single swap point for other backends.
2. **Argo CD repo credential (bootstrap) → imperative apply, never committed.**
   `make argocd-repo` creates the `repo-priv` secret from env (`ARGOCD_REPO_PAT`); the value is never
   committed, and the secret is excluded from the app-of-apps so self-heal can't clobber it. Removed
   entirely when the repo goes public (a public repo needs no credential).
3. **Non-secret config (domains, project IDs, hostnames) → plaintext `environments/<env>/config.yaml`.**

SOPS/KSOPS are not used: no committed-encrypted secrets, no decryption key on the Argo CD repo-server.

## Alternatives considered

- **SOPS + age** (encrypt-and-commit): zero backend dependency and cloud-agnostic, but puts encrypted
  blobs in git and needs KSOPS on the repo-server for Argo CD to decrypt. Rejected as primary; viable
  escape hatch for air-gapped forks.
- **Sealed Secrets**: controller key is cluster-bound and must exist before sealing; fails the
  encrypt-before-a-cluster-exists fork story.
- **Plain Secrets**: never; would leak values in a public repo.

## Consequences

- **+** Zero secret values in git. IAM-controlled. `ExternalSecret`s are portable; forks swap one
  `ClusterSecretStore`. Matches the target production stack (the customer eval uses OpenBao + ESO).
- **−** ESO becomes a platform dependency, and the default backend (GCP SM) couples the default env to GCP.
- **Escape hatch (the fork-dependency tradeoff):** forkers who don't want ESO can either point the
  `ClusterSecretStore` at the `fake`/`kubernetes` provider, or skip ESO and supply native Secrets out-of-band.
  The `ExternalSecret` references are the only ESO-specific surface, and they are isolated per layer.
- **Cross-cloud (off-GKE):** the GSM backend can authenticate from a non-GCP cluster via **keyless Workload
  Identity Federation** (0 long-lived secrets), and the backend remains swappable through the per-layer
  secret contract.
