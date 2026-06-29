---
title: "ADR-0027: Deployment profiles: additive layer-root app-of-apps"
---

**Status:** Accepted

**Selection mechanism superseded by [ADR-0031](/decisions/0031-config-driven-feature-selection)** (config-driven feature selection). Staging (layer
profiles) retained; the per-layer `directory.recurse` all-or-nothing roots are replaced by per-layer
ApplicationSets reading `groups.generated.yaml`.
**Date:** 2026-06-20

## Context

`make root` applied one app-of-apps (`clusters/ai-dev/root.yaml`) that **recursed every child
Application** under `clusters/ai-dev/apps/`. Only three workload apps are manual-sync; the other ~23 (the GIE routing pools, LiteLLM, its
CloudNativePG Postgres, KServe, the sim demos) **all auto-deploy in one shot**. A forker who wants
just the base platform (GitOps + secrets + observability + GPU admission) gets the entire self-hosted
LLM platform stack. There is no way to say "deploy the platform, not the tenant gateway."

The original profile / app-selection blueprint was not built; deployment profiles close it.

Two constraints rule out the obvious mechanisms:

1. **One universal `ApplicationSet`** collides with our **heterogeneous** apps: multi-source Helm
   (`$values` git ref), per-app `ignoreDifferences`, and the manual-sync split. A single
   generator template can't express that variety without per-element overrides that defeat the point.
2. **Profile-directory Kustomize** (a kustomization per profile listing Applications) hits the same
   Argo `LoadRestrictionsRootOnly` wall: a kustomization can't reference Application
   manifests outside its own rooted tree.

## Decision

**Additive layer-roots app-of-apps.** A durable **catalog** of layers + one app-of-apps **root**
per layer; a **profile** is the set of roots you apply.

```
clusters/ai-dev/
  layers/<layer>/      catalog: the child Application manifests, verbatim, sync policies preserved
  roots/<layer>.yaml   one app-of-apps Application recursing layers/<layer>
  projects/platform.yaml   the `platform` AppProject (replaces the permissive `default`)
```

Five layers, cumulative profiles:

| Profile (`make root PROFILE=`) | Roots applied |
|---|---|
| `platform` (default) | platform |
| `serving` | platform, serving |
| `llm-gateway` | platform, serving, routing, llm-gateway |
| `full` | platform, serving, routing, llm-gateway, demos |

There is intentionally **no standalone `routing` profile**: routing's real path has a hard dependency
on `serving` (the raw-vLLM pods backing the InferencePool/EPP), so `routing` only ships inside
`llm-gateway`/`full`, both of which already include `serving`. A future routing-only profile would have
to bundle `serving`.

**Selection = presence, not booleans.** A profile applies its roots; there are no `enabled: false`
toggles. Removing a layer = `kubectl delete -f roots/<layer>.yaml`. Applying a *narrower* profile
does **not** prune wider layers (their roots are separate objects). This is deliberate: switching
to `platform` must never tear down running GPU workloads. `make root` always (re)applies the
`platform` AppProject first.

**Ordering** is preserved two ways: `make root` applies roots in the order
`platform → serving → routing → llm-gateway → demos`, and `argocd.argoproj.io/sync-wave` still
orders the child apps *within* a layer.

### Layer membership and the cross-layer dependencies that fix it

| Layer | Apps | Note |
|---|---|---|
| **platform** | argo-cd, cert-manager, external-secrets(+config), **gateway-api-crds**, keda, kueue, kueue-config, observability, dcgm-metrics, grafana-dashboards | minimal base |
| **serving** | raw-vllm (manual), kserve, kserve-crd | real model-serving runtimes |
| **routing** | agentgateway(+crds), **inference-gateway** (front door + BBR), inference-pool-raw-vllm, inference-routing-real | inference-aware routing |
| **llm-gateway** | cloudnative-pg, litellm-bootstrap, litellm, grafana-litellm | tenant economics edge + spend dashboard |
| **demos** | kserve-demo (manual), inference-demo (manual), inference-pool, inference-pool-model-b-{stable,canary}, **kueue-tenants** | sim/proof artifacts |

Three placements are forced by real dependencies, not aesthetics:

- **Gateway API CRDs → `platform`, but the agentgateway *controller* → `routing`.** KServe runs
  `enableGatewayApi: true` ([ADR-0006](/decisions/0006-raw-vllm-vs-kserve)), so its controller needs the Gateway API CRDs registered to
  start, and KServe is in `serving`, below `routing`. The CRDs are inert API surface, so they sit
  in `platform` (present from the base up). The agentgateway *controller* + GatewayClass + the
  routing logic (InferencePools, EPPs, HTTPRoutes) only matter once you route, so they stay in
  `routing`. This refines the §3 architecture diagram, which groups the whole gateway+GIE stack as
  one "routing" box.
- **CloudNativePG → `llm-gateway`.** The CNPG operator exists only to back LiteLLM's Postgres;
  homing it with LiteLLM keeps the `serving` profile from running a pointless DB operator.
- **The "real GIE routing split" (the necessary refactor).** The front-door **`inference-gateway` Gateway** and
  the **BBR `AgentgatewayPolicy`** lived inside the *sim demo* kustomization
  (`routing/.../demo/`), yet the **real** raw-vLLM path attaches its HTTPRoute to that Gateway and
  matches the `X-Gateway-Base-Model-Name` header **the BBR policy populates**. So the real path
  silently depended on the sim demo being synced. They are extracted to `routing/.../gateway/`
  (routing layer) so every profile from `routing` up has a working front door, fixing a latent
  coupling, not just relocating files.
- **Tenant split.** `team-a`/`team-b` namespaces + their LocalQueues moved from
  `platform/kueue-config` to `workloads/kueue-tenants` (demos layer). The `gpu-cq` ClusterQueue has
  `namespaceSelector: {}`, so it admits any namespace's LocalQueue and does not require the example
  tenants to exist; the base `platform` profile ships only the cluster-scoped quota pool.

### The `platform` AppProject

All Applications and roots move from the built-in `default` project to a named **`platform`
AppProject**, an independent security win. It pins a **`sourceRepos` allowlist** (this repo + the
specific Helm/OCI chart registries) and a **single in-cluster destination**. Cluster/namespace
resource scopes are left `'*'` for now (the stack spans CRDs, ClusterRoles, GatewayClasses,
ClusterQueues, Namespaces…; enumerating them safely needs a live cluster, see Consequences).

## Why staging the mechanism isn't throwaway

`layers/` is the **durable catalog**; only the **selector** is staged. Today the selector is "which
roots you apply." When multi-cluster or install-time pressure is real, the same `layers/` catalog
feeds an **`ApplicationSet` Git-generator + label selector**: additive, zero catalog rework. The
catalog/instance **two-repo split** (catalog here, per-cluster instances elsewhere) is likewise
deferred: it ripples into `fork-init` and the getting-started guide, and buys nothing until there
is a second cluster. Intra-layer toggles (e.g. GPU yes/no) are future **Kustomize components**
inside a layer, not new layers.

## Alternatives rejected

- **One universal `ApplicationSet`**: collides with heterogeneous apps (multi-source Helm,
  `ignoreDifferences`, manual-sync); per-element overrides defeat the simplicity.
- **Profile-dir Kustomize**: hits `LoadRestrictionsRootOnly`.
- **`enabled: false` value toggles**: a values matrix to maintain; "presence = enabled" is simpler
  and matches GitOps (the cluster state is the set of roots that exist).

## Consequences

- A forker deploys the base platform alone (`make root`) and widens deliberately; the cost/blast
  radius of a fresh apply is bounded by the profile.
- The real routing path no longer depends on the sim demo (real GIE routing split), a correctness fix.
- `fork-init` now discovers the canonical repoURL from `clusters/<env>/roots/platform.yaml` (was
  `root.yaml`, removed). All roots/projects/layer apps carry the repoURL, so a fork's `fork-init`
  rewrites them.
- **Validation status.** Author-time + an independent multi-agent review (GO): all 28 apps/5 roots/1
  project parse, the 4 affected kustomizations build, every profile is dependency-complete, fork-init +
  the AppProject allowlist hold. **Live per-profile deploy is NOT yet cluster-validated**: the cluster is
  paused and `kubectl --dry-run=client` does not schema-check the Argo CRDs. This is deliberately deferred
  to the **IaC/OpenTofu substrate ([ADR-0028](/decisions/0028-iac-cloud-substrate))**: a fresh `tofu apply` cluster is the clean-room to deploy each profile in turn
  (`make root PROFILE=platform → serving → llm-gateway → full`) and assert health via the planned
  `make wait/smoke PROFILE=…` + `make doctor`. Profiles + reproducible substrate validate together.
- **Tracked follow-ups:**
  - **Per-profile live validation on a from-zero cluster**: rides the IaC/OpenTofu substrate (see Validation status above).
  - **AppProject cluster-resource scoping**: tighten `clusterResourceWhitelist` from `'*'` to the
    enumerated kinds once a live cluster confirms the full set without breaking syncs.
  - **ApplicationSet migration**: swap the selector when multi-cluster lands (catalog unchanged).
  - **Catalog/instance two-repo split**: deferred until a second cluster justifies the `fork-init`
    churn.
  - Narrowing a profile does not auto-remove wider layers; document `kubectl delete -f roots/…` as
    the teardown path (see `teardown.md`).

Relates to [ADR-0002](/decisions/0002-kueue-quota-admission) (Kueue quota the tenants target), [ADR-0005](/decisions/0005-inference-aware-routing)/[ADR-0006](/decisions/0006-raw-vllm-vs-kserve) (the gateway + KServe couplings that
fix layer membership), [ADR-0013](/decisions/0013-gateway-layering) (LiteLLM, the llm-gateway layer).
