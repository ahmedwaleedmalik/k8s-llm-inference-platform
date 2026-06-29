---
title: "ADR-0031: Config-driven feature selection via ApplicationSet group-roots"
---

**Status:** Accepted
**Date:** 2026-06-22

## Context
ADR-0027 gave per-layer staging (`make root PROFILE=`) but each layer root used
`directory.recurse` → all-or-nothing. A forker could not disable a swappable capability
(e.g. external-dns) without deleting Application YAML from git. We want one human-edited
`config.yaml` to drive which capabilities deploy, for a competent-k8s (not Argo-expert) audience,
without losing verbatim-YAML legibility.

## Decision
Three orthogonal axes: **staging** (which layers, unchanged), **selection** (which capability
groups exist, new), **bring-up** (manual-sync, unchanged).

- Workloads stay verbatim `kind: Application` YAML in `clusters/<env>/catalog/<group>/`.
- `scripts/resolve-groups.sh` turns `config.yaml features:` into `clusters/<env>/groups.generated.yaml`.
- One **ApplicationSet per layer** (git-files generator + post-`selector` on `enabled`/`layer`)
  creates one app-of-apps per enabled group over `catalog/<group>` (`directory.recurse`).

ADR-0027 rejected ApplicationSet for templating heterogeneous *workloads*; that objection does not
apply here: ApplicationSet only generates the **homogeneous group-roots**; the heterogeneity
(multi-source Helm, ignoreDifferences, manual-sync) stays inside the verbatim catalog children.

## Capability groups
`-core` groups always on; optional groups default per the spec table. 13 groups across 6 layers
(platform, serving, routing, llm-gateway, experience, demos). `experience` is split out of `demos`
(real UX apps: open-webui/tabby/key-portal) vs sim/proof artifacts (demos).

## Consequences
- + One config file selects capabilities; disable = flip a bool, prune cascades.
- + Workloads remain plain YAML; adding an app = drop a file in `catalog/<group>/`.
- − Must keep catalog dirs free of Helm/Kustomize files (directory source renders plain YAML only).
- − Empty `groups.generated.yaml` would prune all groups → `make doctor` + `make root` guard against it.
- − Cross-app sync-wave gating not relied upon (children idempotent + retry); see ArgoCD #27917.
- Selection invariants + mitigations: see the design spec.

Supersedes the *selection* mechanism of [ADR-0027](/decisions/0027-deployment-profiles) (its *staging* is retained). Mitigations and full
rationale: `docs/superpowers/specs/2026-06-22-config-driven-feature-selection-design.md`.
