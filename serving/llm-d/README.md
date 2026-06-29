# llm-d (KServe LLMInferenceService) — advanced disaggregated serving

The **integrated, disaggregated serving** path.
One `LLMInferenceService` serving the same small model as
[`raw-vllm`](../raw-vllm), with **prefill/decode disaggregation** + **KV-aware routing**. It runs in
its **own namespace with its own GIE** so its bundled control plane does **not** collide with the
reference agentgateway+GIE path. It is a **supported, opt-in** serving layer for large/multi-node
models, cataloged as an Argo app — not the default, but a first-class path, not an experiment.

## What's here

| File | Purpose |
|---|---|
| `namespace.yaml` | `llm-d` namespace — the isolation boundary. |
| `gateway.yaml` | `llm-d-gateway` (`gatewayClassName=agentgateway`) — the isolated path's own front door. |
| `llminferenceservice.yaml` | `serving.kserve.io/v1alpha1` LLMInferenceService: decode pool + `prefill` pool (disaggregation) + `router.scheduler` (KV-aware EPP). |

Synced by Argo CD as a **manual-sync** app, namespace-isolated from the reference path
(`clusters/ai-dev/catalog/llm-d/llm-d.yaml`).

## Versions (pinned)

| Component | Version | Source |
|---|---|---|
| API | `serving.kserve.io/v1alpha1` (alpha) | KServe `llmisvc` docs |
| KServe (ships the CRD + controller) | `v0.19.0` | already installed (`clusters/.../kserve/`) |
| llm-d serving image | `ghcr.io/llm-d/llm-d-dev:v0.2.2` | KServe llm-d preset |
| llm-d inference scheduler (EPP) | `ghcr.io/llm-d/llm-d-inference-scheduler:v0.2.0` | KServe llm-d preset (created by `router.scheduler`) |
| Model | `Qwen/Qwen2.5-0.5B-Instruct` | same as raw-vllm |

> llm-d is **CNCF Sandbox** and `LLMInferenceService` is a `v1alpha1` API; the versions above are
> pinned. Re-verify the served CRD schema when bumping pins.

## How it stays isolated from the reference GIE

`router.{scheduler,route,gateway}` makes KServe stand up the LLMInferenceService's **own**
InferencePool + EPP scheduler + HTTPRoute, all in the **`llm-d` namespace**, attached to the
**`llm-d-gateway`** declared here. None of it touches the reference `raw-vllm` InferencePool/EPP in
ns `serving` or the shared `inference-gateway` (ns `routing-core`). Two GIE control planes run only
transiently, side by side, while it is synced — exactly the isolation we require.

## Needs >=2 GPUs to demo

Disaggregation = **1 prefill GPU + 1 decode GPU**. On a single GPU
(`GPUS_ALL_REGIONS=1`) only one pool schedules, so the throughput win is not observable there. The
disaggregation/KV-routing path runs on the multi-GPU substrate (Vast); on a single GPU the manifest
demonstrates the **architecture**. Bring-up path (C2):

1. Enable the `llm-d` group (`features.llm-d: true`) and **manual-sync** `llm-d` in Argo.
2. Confirm both pools Ready: a decode pod and a prefill pod, each on its own GPU (`kubectl get pods -n llm-d`).
3. Confirm the bundled scheduler is up: EPP deployment/service + the InferencePool in ns `llm-d`,
   and that it is **distinct** from the `raw-vllm` InferencePool in ns `serving`.
4. Drive a long-prompt workload through `llm-d-gateway`; observe prefill-side vs decode-side
   activity split and KV/prefix-aware backend selection in the scheduler logs.
5. Capture the publishable comparison vs raw-vllm+GIE (TTFT/TPOT/throughput) for C3.

## Prerequisites

`LLMInferenceService` needs the KServe **llmisvc** install, which is separate from the classic KServe charts:
`kserve-llmisvc-crd` + `kserve-llmisvc-resources` (controller/webhook) + the well-known
`LLMInferenceServiceConfig` presets from the KServe repo `config/llmisvcconfig` (the `router.scheduler{}` here
references `kserve-config-llm-scheduler`). These are now in `clusters/ai-dev/catalog/kserve/kserve-llmisvc*.yaml`
(install with the `kserve` group). Non-GKE GPUs also need `runtimeClassName: nvidia` on `spec.template` and
`spec.prefill.template`.

## Teardown

It is its own namespace + manual-sync app. Disabling/deleting the app cascades a clean delete (the
finalizer); deleting the `llm-d` namespace removes everything. The reference path is untouched.
