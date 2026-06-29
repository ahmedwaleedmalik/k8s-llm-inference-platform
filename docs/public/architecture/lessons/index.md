---
title: "Concepts"
---

The non-obvious decisions: the ones that are not visible until you run a GPU inference platform, or that
the obvious design gets wrong. Read this page before forking. A few carry a deeper page.

## GPU & serving

**GPU utilization is a lying signal for LLM serving.**
Under PagedAttention, vLLM holds the GPU near 100% at all times, so GPU-util tells you nothing about
load. In-flight request count is no better. vLLM exposes the real saturation signal,
`vllm:num_requests_waiting` (queued, not yet running), and that is what KEDA scales on.
→ [GPU signals and autoscaling](/architecture/lessons/gpu-signals-and-autoscaling)

**Let the provider manage GPU drivers, until portability forces your hand.**
Managed GPU drivers (as on GKE) avoid a class of driver/device-plugin blockers. But portability
inverts this: off a managed cloud, *you* run the NVIDIA GPU Operator (driver, device-plugin, DCGM,
time-slicing) yourself. Managed where it exists, the Operator as the portable fallback.
→ [Portability is a substrate problem](/architecture/lessons/portability)

**Start at the lowest abstraction you fully understand.**
The default serving layer is raw vLLM: a hand-rolled Deployment+Service+PVC where every operational
concern is yours. KServe's `InferenceService` is added only where its lifecycle features (canary,
model governance, scale-to-zero) earn the extra control plane. Reach for the platform when the
complexity is real, not before. → [Serving layers compared](/architecture/serving-layers)

## Routing & tenancy

**The AI gateway and the inference router are different layers; do not conflate them.**
LiteLLM (virtual keys, per-key budgets, TPM/RPM, spend ledger, one OpenAI `/v1` facade) sits *above*
GIE (inference-aware endpoint selection: KV-cache, queue depth, model/canary splits). One is tenant
economics, the other is request routing. Collapsing them into one box loses both jobs.

**A control that isn't forced is not a control.**
Budgets and GPU quota can exist logically (keys in LiteLLM, quota in Kueue) and still be bypassable
because nothing forces traffic and workloads through them. Single-tenant labs never hit this; the
moment two teams share a cluster, the enforcement path has to be mandatory and fail closed on budget.

## Model delivery & cold start

**Cold start is four independent latencies, not one number.**
Scale-from-zero means every wake is a cold start, and a 0.5B/1GB model hides the physics a 30-70 GB
image exposes. Image pull, model load, GPU node provisioning, and runtime warm-up each have their own
fix and owner. Turning on Image Streaming fixes one lever and leaves three.
→ [Cold start is four latencies](/architecture/lessons/cold-start)

**Ship models as digest-pinned OCI images.**
A modelcar (`oci://`, pinned by `@sha256`) is the model-delivery default: forkable, air-gap-friendly,
and zero Hugging Face egress at serve time. The model becomes a versioned artifact like any other
image.

## Platform boundaries

**IaC owns the cloud substrate; GitOps owns in-cluster lifecycle. The boundary is hard.**
OpenTofu makes the cluster, node pools, identity, and IAM. Argo CD makes everything inside
Kubernetes. Neither crosses into the other's half. That split makes a fork reproducible
instead of a pile of guessed provider flags.

**Secret values never enter git or IaC state.**
External Secrets Operator materializes Kubernetes Secrets from a cloud secret manager, with keyless
access via workload identity. Git holds the *contract* (which secrets exist, by name and owner),
never the values.

**Profiles are additive layers you widen, not configs you switch.**
`make root PROFILE=serving|llm-gateway|full` applies a cumulative set of app-of-apps roots. You add a
layer, you don't swap a config, so a fork can deploy exactly as much platform as it needs.

**Portability is a secrets + DNS + storage-class + GPU-stack problem, not an app problem.**
The in-cluster stack is the portable part; what changes between clouds is the substrate underneath
it. Moving to a second cloud means re-solving those four, not rewriting the platform.
→ [Portability is a substrate problem](/architecture/lessons/portability)
