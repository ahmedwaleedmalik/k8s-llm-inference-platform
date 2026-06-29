---
title: "ADR-0025: Cold start: four independent levers"
---

**Status:** Accepted
**Date:** 2026-06-20

## Context

Scale-from-zero ([ADR-0014](/decisions/0014-autoscaling) deployment profiles: replica floor is a profile knob, lab idles at 0) means every wake is a
**cold start**. For a real model the wake is dominated by physics the lab hides: a 0.5B/1GB modelcar
boots in seconds, a 30-70 GB image does not. The north star forbids demoting a product
concern because the lab artifact (single GPU, 0.5B, $0-idle) makes it look cheap. So cold start is
designed as a **product concern**, demonstrated cheaply.

Cold start is **not one number**: it is four independent latencies that add up, each with its own
fix and its own owner. Conflating them (e.g. "just use Image Streaming") fixes one lever and leaves
the other three. The research (`2026-06-20-sso-coldstart.md` TOPIC 2) separates them:

1. **Model weight load:** pulling/mapping weights into the engine.
2. **Container image pull:** getting the multi-GB OCI image onto the node.
3. **Node 0→1:** provisioning a GPU node when the pool is empty (minutes).
4. **Runtime / scale-from-zero:** what vLLM does between container-start and `/health` passing.

This ADR also has to honor the [ADR-0016](/decisions/0016-model-delivery) generic-first rule: generic K8s primitives are the default;
cloud-specific tools are optional and profile-gated, never a dependency.

## Decision

Treat cold start as **four independent levers** with a **cloud-agnostic BASELINE** (the default,
ships in every profile) and **per-cloud ACCELERATORS** (optional, profile-gated). Lever 4
(runtime) is **DECIDED and applied now** to `qwen-oci`; levers 1-3 are sequenced (model delivery at scale).

### Lever 1: Model weight load (baseline; GKE accelerators optional)

- **Baseline (cloud-agnostic):** weights ship as the digest-pinned OCI modelcar ([ADR-0016](/decisions/0016-model-delivery)), HF fully
  offline (`HF_HUB_OFFLINE=1` + `TRANSFORMERS_OFFLINE=1`), and **`--load-format runai_streamer`**
  streams weights into GPU memory in parallel (engine-native, no cloud dependency, ≫ tensorizer from
  object storage). `LocalModelCache` pre-pulls weights node-warm ([ADR-0016](/decisions/0016-model-delivery), model delivery at scale: product
  capability, deferred by sequencing only).
- **Accelerators (profile-gated, GKE):** **Hyperdisk ML** (RO `READ_ONLY_MANY`, ~11.9× faster, RO
  fan-out to thousands of nodes) for very large models; GCS-FUSE as a warm cache (file-cache +
  parallel-download). Optional; never depended on.

### Lever 2: Container image pull (PRODUCT-CRITICAL, not optional)

- For a real model the OCI image is **30-70 GB and image-pull dominates cold start** ([ADR-0016](/decisions/0016-model-delivery)). The
  **concern is product-critical**; only the *GKE-specific tool* is optional.
- **Baseline (cloud-agnostic):** lean base + **zstd-compressed layers**; **in-region registry**
  (no cross-region egress); **digest-pinned ⇒ `IfNotPresent`** so a warm node never re-pulls
  ([ADR-0016](/decisions/0016-model-delivery): a tag/`:latest` forces `Always`); **`LocalModelCache` node-warm pre-pull** so
  scale-out doesn't pay first-pull per node.
- **Accelerators (profile-gated, GKE):** **GKE Image Streaming** (lazy-pull from Artifact Registry,
  ~191s→~30s first start); **secondary boot disks** to preload images/weights for >~20 GB.

### Lever 3: Node 0→1 (baseline buffer; GKE compute classes optional)

- **Baseline (cloud-agnostic):** a **warm buffer** via low-priority pause pods (hold a GPU node warm
  so a real pod preempts instead of waiting minutes for provisioning). Reservations/DWS for scarce GPUs.
- **Accelerators (profile-gated, GKE):** **Custom Compute Classes** (Spot→on-demand fallback +
  migrate-back, GA); **GKE Active Buffer/CapacityBuffer** *(Preview; GPU support unconfirmed, verify
  before relying on it)*. Optional; the pause-pod buffer is the portable default.

### Lever 4: Runtime (DECIDED, applied to `qwen-oci` now)

These are the cheap, lab-visible startup traps from the research "Top real issues". Applied to
`serving/kserve/inferenceservice-modelcar.yaml`:

- **`/dev/shm` tmpfs ≥16Gi.** The container default `/dev/shm` is tiny; NCCL falls back / hangs on
  init. Mount an `emptyDir{medium: Memory, sizeLimit: 16Gi}` at `/dev/shm`.
- **`NCCL_CUMEM_ENABLE=0`.** Paired with the tmpfs above: the known-good combo against the NCCL
  init hang.
- **torch.compile / HF cache at `/root/.cache`.** `emptyDir` in the lab (per-pod, cleared on
  restart); **back it with a persistent volume in production** so CUDA-graph compilation is not
  re-captured on every cold start (>10s per boot).
- **`--gpu-memory-utilization`: 0.7-0.8 is the CEILING, 0.6 conservative-safe.** Higher starves the
  transient startup VRAM (graph capture / activation buffers) and trips startup OOM before `/health`.
- **`--enforce-eager` only when cold-start beats throughput.** CUDA-graph capture adds >10s; skip it
  to wake faster, keep it when steady-state throughput matters. A per-profile call, not a default.
- **vLLM Sleep Mode for multi-model.** L1 RAM offload, 18-200x faster wake than a full reload:
  the right tool when one GPU multiplexes several models (future; not single-model `qwen-oci`).

We do **not** hand-write `shareProcessNamespace`/`securityContext`; the KServe webhook injects them
([ADR-0016](/decisions/0016-model-delivery)). We add only the volumes + mounts + env.

## Alternatives considered

- **One-knob fix (e.g. only GKE Image Streaming).** Rejected: fixes lever 2 alone, leaves model load,
  node 0→1, and runtime untouched. The four levers are additive and independent.
- **GKE accelerators as the baseline (Hyperdisk ML / Image Streaming / Custom Compute Classes).**
  Rejected as default: cloud-specific, breaks the portability claim ([ADR-0016](/decisions/0016-model-delivery)). Kept as
  optional profile-gated scale-paths.
- **Keep a warm replica (`minReplicas: 1`) to dodge cold start entirely.** That is the [ADR-0014](/decisions/0014-autoscaling) deployment-profiles
  knob, not a cold-start *fix*: it trades $0-idle for latency. Orthogonal; both can apply.
- **Bake torch.compile cache into the image.** Rejected: re-bakes on every model/engine bump and
  couples cache to image lifecycle; the `/root/.cache` volume decouples it.
- **Drop runai_streamer, plain HF load.** Rejected for the baseline: serial load, slower; and HF
  online load reintroduces the egress dependency ([ADR-0016](/decisions/0016-model-delivery) HF-429).

## Consequences

- **+** Cold start is now a tractable, per-lever design with a portable default everywhere and
  cloud accelerators layered on by profile, no cloud dependency in the baseline ([ADR-0016](/decisions/0016-model-delivery) rule held).
- **+** The runtime traps (lever 4) are fixed for `qwen-oci` at near-zero cost and are validated on
  the 1GB/1-GPU lab, exercising the same code paths a real model hits.
- **−** The 16Gi `/dev/shm` tmpfs is charged against the pod memory limit; size the pod memory above
  shm + engine RSS, or the kernel OOM-kills on shm allocation.
- **−** The `/root/.cache` `emptyDir` is per-pod in the lab, so scale-to-zero re-captures CUDA graphs
  on the next cold start (a validation caveat of $0-idle, *not* a reason to skip the cache; production
  uses a persistent volume).
- **-** Levers 1-3 baseline (runai_streamer, LocalModelCache, zstd/in-region, pause-pod buffer) are
  sequenced to model delivery at scale; until then the lab pays the un-optimized model-load + image-pull on a true cold node.
- **−** `--enforce-eager` and Sleep Mode are deferred per-profile decisions; choosing wrong trades
  wake latency for steady-state throughput (or vice versa).

## References

- Builds on the model-delivery default and generic-first rule [ADR-0016](/decisions/0016-model-delivery); the scale-from-zero floor
  knob [ADR-0014](/decisions/0014-autoscaling); the serving-layer / KServe substrate decision [ADR-0006](/decisions/0006-raw-vllm-vs-kserve) (cold start is the cost
  of `minReplicas: 0`). Cloud-specific accelerators stay profile-gated.
- `serving/kserve/inferenceservice-modelcar.yaml` (`qwen-oci`, lever 4 applied). vLLM `v0.23.0`; KServe v0.19.0.
  vLLM `runai_model_streamer`, `sleep_mode`, `cuda_graphs`; GKE hyperdisk-ml / image-streaming /
  custom-compute-classes / active-buffer; `vllm#24541`, `vllm#23115`, `vllm#21051`.
