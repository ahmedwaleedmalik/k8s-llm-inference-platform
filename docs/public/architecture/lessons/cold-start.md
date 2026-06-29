---
title: "Cold start"
---

Scale-from-zero means every wake is a cold start. A 0.5B/1GB model boots in seconds and hides the physics a 30-70 GB model exposes. The trap is treating cold start as one number with one fix: turning on Image Streaming solves one lever and leaves the other three untouched. They are independent and additive.

## The four levers

1. **Model weight load**: pulling and mapping weights into the engine.
2. **Container image pull**: getting the multi-GB OCI image onto the node.
3. **Node 0→1**: provisioning a GPU node when the pool is empty, which takes minutes.
4. **Runtime / scale-from-zero**: what vLLM does between container start and `/health` passing.

Each has its own owner and its own fix. Conflating them means you optimize one and still pay the rest.

## Portable baseline, cloud accelerators on top

The design separates a cloud-agnostic baseline (ships in every profile) from per-cloud accelerators (optional, profile-gated). Making cloud-specific tools the default would break the portability claim.

- **Weight load.** Baseline: weights ship as a digest-pinned OCI modelcar, Hugging Face fully offline (`HF_HUB_OFFLINE=1` + `TRANSFORMERS_OFFLINE=1`), and `--load-format runai_streamer` streams them into GPU memory in parallel with no cloud dependency. On GKE, Hyperdisk ML (read-only, fan-out to many nodes) is an optional accelerator for very large models.
- **Image pull.** Baseline: lean base plus zstd-compressed layers, an in-region registry to avoid cross-region egress, and digest-pinning so the pull policy is `IfNotPresent` and a warm node never re-pulls (a tag or `:latest` forces `Always`). On GKE, Image Streaming lazy-pulls from Artifact Registry.
- **Node 0→1.** Baseline: a warm buffer of low-priority pause pods holds a node warm so a real pod preempts instead of waiting on provisioning. On GKE, Custom Compute Classes add Spot→on-demand fallback.

## Runtime traps are cheap and load-bearing

The runtime lever is fixed now on the modelcar `InferenceService`, at near-zero cost, and it exercises the same code paths a real model hits:

- **`/dev/shm` tmpfs ≥16Gi.** The container default is tiny and NCCL hangs on init. Mount an `emptyDir{medium: Memory, sizeLimit: 16Gi}` at `/dev/shm`, paired with `NCCL_CUMEM_ENABLE=0`: the known-good combo against the NCCL init hang.
- **`--gpu-memory-utilization` 0.7-0.8 is the ceiling; 0.6 is conservative-safe.** Higher starves the transient startup VRAM (graph capture, activation buffers) and trips a startup OOM before `/health`.
- **`--enforce-eager` only when cold-start wins over throughput.** CUDA-graph capture adds >10s; skip it to wake faster, keep it when steady-state throughput matters. A per-profile call.
- **Back `/root/.cache` with a persistent volume in production** so CUDA-graph compilation is not re-captured on every cold start. A per-pod `emptyDir` re-captures on each wake.

Note the cost charged back: a 16Gi `/dev/shm` tmpfs counts against the pod memory limit, so size pod memory above shm plus engine RSS or the kernel OOM-kills on allocation.
