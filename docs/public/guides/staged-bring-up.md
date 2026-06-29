---
title: "Staged bring-up"
---

Two orthogonal staging mechanisms keep a fresh apply cheap and prevent selfHeal from fighting
manual cost actions (`make vllm-up/down`, the KServe idle-pause):

1. **Deployment profiles (which layers)**: `make root PROFILE=…` applies the per-layer
   ApplicationSets in `clusters/ai-dev/appsets/` (additive: `platform` ⊂ `serving` ⊂ `llm-gateway`
   ⊂ `full`, where `full` adds the `experience` and `demos` layers). The per-group catalog lives
   under `clusters/<env>/catalog/`.
   **Capability selection (which groups within a layer)** is config-driven: edit `config.yaml`
   `features:`, run `make resolve-groups`, then `make root`; disabling a group prunes it.
2. **Sync policy (which workloads deploy)**: within whatever profile, most apps are **auto-sync**;
   the paid/heavy workload apps are **manual-sync**, created as `Application` objects on `make root`
   but **not deployed** until an explicit sync. This is the cost gate: the GPU node and the model
   pods only exist when you bring them up.

| Manual-sync app | Layer | Why manual |
|---|---|---|
| `raw-vllm` | serving | GPU cost; `make vllm-up/down` owns replicas |
| `coder-chat`, `coder-fim`, `coder-agent` | serving | GPU cost; coding-assistant models, brought up with `argocd app sync` |
| `kserve-demo` | demos | CPU ISVC, forces a 2nd node; paused when idle |
| `inference-demo` | demos | sim routing demo, brought up deliberately |
| `n8n` | experience | workflow surface; its own key-minter Job, brought up deliberately |

Everything else (platform infra, routing data plane, LiteLLM, sim pools, tenants) is auto-sync.

![GitOps bring-up model showing OpenTofu-owned substrate, Argo CD-owned in-cluster apps, additive profiles, and manual-sync cost gates](../assets/diagrams/gitops-bring-up-model.png)

## Bring-up order

1. **Platform**: `make root` (default `PROFILE=platform`) applies the `platform` AppProject + the
   platform root; auto-sync apps reconcile by sync-wave (CRDs/operators → controllers →
   config/observability). Widen the profile as you go (`make root PROFILE=serving|llm-gateway|full`).
   Wait for apps Healthy:
   ```sh
   make wait PROFILE=platform
   make doctor PROFILE=platform
   ```
2. **GPU smoke gate**: needs the `serving` profile (`make root PROFILE=serving`) so the `raw-vllm`
   Application exists. Bring serving up deliberately, prove the GPU path, then scale back to $0:
   ```sh
   make root PROFILE=serving
   make wait PROFILE=serving
   argocd app sync raw-vllm        # deploys the Deployment at replicas:0 (no node yet)
   make vllm-up                    # scales to 1 → brings up the L4 node (costs while running)
   make smoke PROFILE=serving      # doctor + authenticated /v1/chat/completions → 200
   make vllm-down                  # scales to 0 → releases the node ($0 idle)
   ```
3. **Demo / KServe**: needs the `full` profile (`make root PROFILE=full`) so the demos layer's
   Applications exist. Sync on demand, tear down when idle:
   ```sh
   argocd app sync inference-demo  # sim-backed routing demo ($0-GPU)
   argocd app sync kserve-demo     # CPU ISVC; idle-pause via runbook kserve.md §8
   ```

## Why manual (not just selfHeal off)

- `raw-vllm` replicas are scaled for cost; `ignoreDifferences` on `/spec/replicas` +
  `RespectIgnoreDifferences` keep a sync from reverting `make vllm-up`.
- `kserve-demo` idle-pause sets `serving.kserve.io/stop=true` live; with auto-sync, selfHeal
  reverts it (the reason the annotation used to be baked into the manifest, now removed).
- Manual sync also means a forker doesn't pay for the GPU/model pods on first `make root`.

To pause an already-running manual app's drift entirely, `argocd app set <app> --sync-policy none`
is unnecessary here; they're already manual, so just don't sync them.
