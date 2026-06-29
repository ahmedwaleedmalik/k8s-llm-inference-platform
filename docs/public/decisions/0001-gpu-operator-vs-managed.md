---
title: "ADR-0001: GKE-managed GPU stack (not a self-managed GPU Operator)"
---

**Status:** Accepted, revised 2026-06-14 (originally chose self-managed; reversed after hitting two GKE-specific blockers, below). Amended 2026-06-25: the operator path is now wired behind the `gpu_stack` config knob (`gke-managed` default, `operator` for non-GKE) instead of being a deferred manual step.
**Date:** 2026-06-13 (revised 2026-06-14, amended 2026-06-25)

## Context

GKE can install and operate the GPU stack for you (driver, container runtime
configuration, and the device plugin) via `gpu-driver-version=default`. The
alternative is to run the **NVIDIA GPU Operator** and own that stack ourselves
(driver, container-toolkit, device-plugin, DCGM, GPU-feature-discovery), which is
attractive for control, visibility, and cloud portability.

We initially chose the self-managed Operator with `driver.enabled=true` on Ubuntu
nodes. In practice, operator-managed drivers on GKE hit two blockers:

1. **driver-validation path mismatch.** With `driver.enabled=true` the operator
   installs the driver to its default `/run/nvidia/driver`, but the GKE-oriented
   override `hostPaths.driverInstallDir=/home/kubernetes/bin/nvidia` pointed
   driver-validation at an empty directory, so it looped forever. Fixable by
   dropping the override, but it only exposed the next blocker.
2. **container-toolkit cannot register the `nvidia` runtime in GKE's containerd**
   ([gpu-operator#1679](https://github.com/NVIDIA/gpu-operator/issues/1679)). The
   toolkit writes a drop-in to `/etc/containerd/conf.d/99-nvidia.toml` and SIGHUPs
   containerd, but GKE does not use `/etc/containerd/config.toml` at the standard
   path and does not import that drop-in directory, so the runtime never registers.
   Every `runtimeClassName: nvidia` pod (device-plugin, DCGM, validator) then fails
   sandbox creation with `no runtime for "nvidia" is configured`, and the GPU is
   never advertised. This is the unsupported, finicky path on GKE.

## Decision

Use the **GKE-managed GPU stack**: GKE installs the driver, configures containerd,
and runs the device plugin.

- Node pool created with `--accelerator=...,gpu-driver-version=default` on a
  **COS** image (`COS_CONTAINERD`). No `gke-no-default-nvidia-gpu-device-plugin`
  label, no `gpu-driver-version=disabled`.
- No GPU Operator. `nvidia.com/gpu` is advertised by GKE's device plugin.
- GPU/DCGM metrics come from a **standalone `dcgm-exporter`** (a separate
  observability concern), not the Operator.
- L4, scale-to-zero (0 nodes idle); a GPU node appears only when a pod requests
  `nvidia.com/gpu`.

## Alternatives considered

- **Self-managed GPU Operator, `driver.enabled=true`** (the original choice):
  rejected on GKE for blocker (2) above. `driver.enabled=false` does **not** avoid
  it: the operator's toolkit still runs and still fails to configure GKE's
  containerd. The portable, cloud-neutral story is real and worth revisiting on a
  non-GKE / generic-Kubernetes target, where the Operator is the right tool. Tracked
  as a deferred task.
- **Fully managed, no DCGM:** rejected. GPU metrics (DCGM) are a platform
  requirement; we add `dcgm-exporter` standalone.

## Consequences

- **+** Robust, supported GPU provisioning on GKE; `nvidia.com/gpu` works out of
  the box; no containerd surgery.
- **-** Driver lifecycle is GKE's, not ours; this part of the stack is not
  cloud-portable on the `gke-managed` path.
- The two operator-on-GKE failure modes are captured in
  `docs/public/guides/gpu-debugging.md` as the evidence behind this reversal.

## Amendment (2026-06-25): selectable via `gpu_stack`

The managed-vs-operator choice is now a config knob, `gpu_stack` in
`environments/<env>/config.yaml`, so the portable path is GitOps-native rather than a manual
side-step (the same selection pattern as `secret_backend` / `secret_store_auth`):

- `gke-managed` (default): the decision above. GKE-managed stack, DCGM from `gke-managed-system`.
- `operator`: deploy the **NVIDIA GPU Operator** (chart `gpu-operator`, pinned) for non-GKE
  substrates (Hetzner / bare-metal / Vast). `make resolve-groups` toggles the `gpu-operator`
  Application group and `scripts/resolve-gpu.sh` renders the DCGM scrape target.
- `none`: CPU-only clusters; no GPU stack, no DCGM metrics.

Do **not** set `operator` on GKE: blocker (2) above (containerd runtime registration) still applies.
`make doctor` warns on the substrate/`gpu_stack` mismatch. The node prerequisites for the operator
path (matching kernel headers; Secure Boot off on Ada) remain a substrate concern, not platform
config.
