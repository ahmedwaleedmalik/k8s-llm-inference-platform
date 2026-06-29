---
title: "ADR-0016: Model delivery via digest-pinned OCI modelcar as the cloud-agnostic default"
---

**Status:** Accepted
**Date:** 2026-06-20

## Context

ADR-0006 deferred **model delivery** as its own decision: HF self-download is fragile (the cluster
egress IP is persistently HF-429-rate-limited even with a token), so the `qwen-cpu` demo pre-stages
weights onto an RWO PVC and serves offline. That pattern doesn't scale: it pins a model to one node,
needs out-of-band `kubectl cp`, and says nothing about large models, many replicas, or air-gap. The
candidates ADR-0006 listed: per-pod HF pull, a shared **RWX** cache, KServe **LocalModelCache**
(node-local pre-pull, v0.17+), or **OCI "modelcar"** (`oci://` weights-in-image). This decision
settles model delivery at scale, and GPU-validates the KServe path (closing the ADR-0006 CPU-only gap).

This also forces a **platform-wide design rule**: when do we reach for cloud-specific accelerators
(GKE Hyperdisk ML, GCS-FUSE, Image Streaming, Custom Compute Classes) vs generic K8s primitives? The
platform's public claim is "GKE-verified / portable-by-design", so the default
must stay portable.

## Decision

**Adopt the digest-pinned OCI modelcar (`oci://reg/model@sha256:...`) as the DEFAULT model-delivery
primitive, on the KServe path.**

- **Modelcar mechanism (KServe >=0.14, default-on v0.19):** the model ships as an OCI image (`busybox`
  + `COPY data/ /models/`). KServe sees `storageUri: oci://...` and injects a sidecar + init-container,
  `shareProcessNamespace: true`, a shared `/mnt` volume, and an `ln -sf` so the weights appear at
  `/mnt/models`: **symlinked, not copied** (the big-model win: no 2x disk, fast start). Works with our
  **custom-container** predictor because injection keys off the container named `kserve-container`
  (which ADR-0006 already uses). vLLM reads `--model=/mnt/models`.
- **Digest-pinned, never `:latest`.** A `@sha256:` ref pins `IfNotPresent` (node-cached after first
  pull); a tag/`latest` forces `Always` and re-pulls the multi-GB image on every pod start.
- **Cloud-agnostic.** Any OCI registry works; air-gap via a mirror (supply-chain integrity).
  This is why modelcar is the *default* and not a GKE-specific feature.
- **Generic-first rule (platform-wide):** generic, K8s-native primitives are the **default**; cloud-
  specific *implementations* (Hyperdisk ML, GCS-FUSE, GKE Image Streaming, Custom Compute Classes) are
  **optional, profile-gated, and clearly labelled**. **Distinction (lab-vs-product):**
  for real models the OCI image is **30-70 GB and image-pull dominates cold
  start**, so **fast large-image delivery is a PRODUCT-CRITICAL concern, not optional.** What is
  optional is the *GKE-specific tool*; the **concern itself is tracked as product-critical** with a
  **cloud-agnostic baseline** (lean/zstd images, in-region registry, digest→`IfNotPresent` node
  caching, LocalModelCache node-warm pre-pull, the cloud-agnostic node-warming stage) and **per-cloud accelerators** layered on top
  (GKE Image Streaming ~191s→30s, Hyperdisk ML, the per-cloud cold-start accelerators stage profile). We *demonstrate* it cheaply at
  1GB/1-GPU; we do **not** scope it away because the lab model is small.
- **KServe is the model-delivery substrate.** Modelcar and (later) LocalModelCache are KServe-native;
  raw-vLLM stays the simple/benchmark endpoint. This extends KServe's role beyond ADR-0006's "lifecycle
  + ingress" framing, so we **amend ADR-0006** (done, dated note).

**LocalModelCache is a PRODUCTION capability, deferred by SEQUENCING only.** For real customers on
**warm multi-node GPU pools**, the node-local pre-pull (DaemonSet warming the node image cache)
eliminates per-node first-pull latency on scale-out. It is **not optional**; it is deferred to the cloud-agnostic node-warming stage
purely because the delivery-mechanism stage proves the delivery mechanism first. The lab's scale-to-zero (which deletes the node
**and** its node-warm cache, so the next cold start re-pulls) is a **validation caveat of a $0-idle
single-GPU lab, never a reason to demote LocalModelCache**.

## Alternatives considered

- **Per-pod HF self-download.** Rejected as default: fragile (egress-IP HF-429), no air-gap story, slow
  cold start per pod, no caching. Fine for a forker on un-throttled egress (`--model=<hf-id>`).
- **Shared RWX cache (Filestore / NFS).** Useful for live canary (revisions spread across nodes,
  ADR-0006 −) and multi-replica reads, but adds a stateful RWX volume to operate and a copy/stage step;
  it's a complement, not the delivery default. Modelcar's image registry is the simpler portable single source of truth.
- **KServe LocalModelCache (now).** Not rejected, **sequenced to the cloud-agnostic node-warming stage** (see above). It layers *on top of*
  the OCI-image delivery (warms the node cache), so the delivery mechanism lands first.
- **GKE accelerators as the default (Hyperdisk ML / GCS-FUSE / Image Streaming).** Rejected as default:
  cloud-specific, breaks portability. Kept as the **optional profile-gated scale-path** (the per-cloud cold-start accelerators stage).
- **Bake weights into the vLLM image directly (no modelcar sidecar).** Rejected: couples model lifecycle
  to engine lifecycle (re-build/re-push on every vLLM bump), and loses KServe's `storageUri` contract +
  the symlink/no-copy mechanism.

## Consequences

- **+** Cloud-agnostic, air-gap-friendly, big-model-ready delivery with immutable digest provenance; no
  egress dependency at serve time (`HF_HUB_OFFLINE=1`). Subsequent pods on a warm node start instantly.
- **+** ADR-0006's custom-container objection dissolves: the old "model+runtime force-injects
  `/mnt/models`" complaint is moot because the weights now *are* at `/mnt/models` (via the symlink), with
  a custom container.
- **-** **Node image-layer disk** is the new sizing constraint: the full image (30-70 GB for a real
  model) is pulled to the node's containerd storage. Size the GPU node boot/image disk (>=200 GB) or hit
  `ImageGCFailed` / disk-pressure eviction. (This is the trade-off LocalModelCache / RWX PVC address.)
- **−** A build+push step enters the model lifecycle (`scripts/build-modelcar.sh` / Cloud Build); the
  digest must be re-pinned on every model change.
- **RESOLVED 2026-06-20 (scratch-ns smoke):** a custom-container modelcar wires `/mnt/models` via the
  **`STORAGE_URI` env on `kserve-container`**: KServe then injects the modelcar sidecar + init + the
  symlink (verified: pod went 1→2 containers + init). **Not** `predictor.model.storageUri` (the webhook
  rejects `model` + `containers` together) and **not** the `serving.kserve.io/storageUri` annotation (no
  injection). The committed `inferenceservice-modelcar.yaml` uses the `STORAGE_URI` env accordingly.
- **−** `shareProcessNamespace: true` (webhook-injected) shares the PID namespace across pod containers;
  blast radius is the model sidecar + vLLM in a single-tenant pod. Don't co-locate untrusted sidecars.

## Validation: live GPU serve (2026-06-22)

**Status: GPU-validated end-to-end** on the canonical IaC cluster (L4; vLLM v0.23.0, KServe v0.19.0). The
`qwen-oci` ISVC pulled the digest-pinned OCI modelcar, KServe injected the modelcar init+sidecar, vLLM
loaded `model=/mnt/models` with `HF_HUB_OFFLINE=1`, and `/v1/chat/completions` returned **200**: weights
served from the image, **zero HF egress**. Closes the [ADR-0006](/decisions/0006-raw-vllm-vs-kserve) "KServe never GPU-tested" gap.

**Three forker traps, all committed (a vanilla forker hits each):**

1. **Build:** **`huggingface-cli download` is removed in `huggingface_hub` 1.x** (hard-exits, "use `hf`"),
   and the `hf` replacement parses `--exclude` differently (extra patterns swallowed as positional
   filenames → empty `data/` → `COPY data/` fails). **Fix:** both `cloudbuild.yaml` and
   `scripts/build-modelcar.sh` now call the stable Python API
   `snapshot_download(model, local_dir='data', ignore_patterns=[...])`, the same call the raw-vllm
   pre-stage init uses (which never broke).
2. **Serve, `KeyError: getpwuid(): uid not found: 1010`.** KServe runs the predictor as a non-root UID
   with no `/etc/passwd` entry; vLLM/torch call `getpass.getuser()`, which falls through to
   `pwd.getpwuid()`. **Fix:** set `USER` env (read before the passwd lookup).
3. **Serve, `PermissionError: '/.cache'`.** `HOME` is unset, so `~/.cache` resolves to `/.cache`
   (unwritable as non-root); flashinfer + torch.compile `mkdir` their workspace under `$HOME`. **Fix:**
   set `HOME=/tmp`.

Any **custom-container** ISVC on KServe inherits a **non-root securityContext with no
passwd entry and unset `HOME`**: set `USER` + `HOME` env, or runtimes that assume a real user (vLLM,
torch, flashinfer, HF) crash before `/health` ever passes. (raw-vllm avoids this, different security
context.) Both envs are now in `inferenceservice-modelcar.yaml`.

## References

- Resolves the [ADR-0006](/decisions/0006-raw-vllm-vs-kserve) follow-up (model delivery at scale); [ADR-0006](/decisions/0006-raw-vllm-vs-kserve) amended (KServe = delivery
  substrate). Generic-first gating applies. Replica floor
  as a profile knob: [ADR-0014](/decisions/0014-autoscaling) (deployment profiles).
- `serving/kserve/inferenceservice-modelcar.yaml` (`qwen-oci`), `serving/kserve/modelcar/`,
  `scripts/build-modelcar.sh`, `platform/kserve/values.yaml` (`enableModelcar: true`), runbook
  `kserve-modelcar.md`. KServe OCI/Modelcar (stable v0.14, default-on
  v0.15.2). vLLM `v0.23.0`; KServe v0.19.0.
