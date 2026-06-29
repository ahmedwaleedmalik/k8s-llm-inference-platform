---
title: "Operational gotchas"
---

The integration failures that do not show up in any single component's docs, because they live in the
seam between two of them. Each one cost real debugging time. If you fork this platform, read these
before you hit them.

## vLLM V1 renamed its metrics

**Symptom.** Dashboards go blank and KEDA triggers stop firing after a vLLM upgrade, with no error,
just a metric that no longer exists.

**Cause.** The vLLM V1 engine renamed core serving metrics: `gpu_cache_usage_perc` became
`kv_cache_usage_perc`, and `time_per_output_token_seconds` became `inter_token_latency_seconds`.
Anything pinned to the old names silently reads zero.

**Fix.** Pin dashboards, alerts, and KEDA Prometheus triggers to the V1 names
(`vllm:kv_cache_usage_perc`, `vllm:inter_token_latency_seconds`). Treat a vLLM major bump as a metrics
contract change, not just an image tag.

## GKE already runs a DCGM exporter

**Symptom.** Installing the NVIDIA `dcgm-exporter` on GKE produces duplicate GPU metrics, scrape
conflicts, or a daemonset that collides with one you did not deploy.

**Cause.** GKE embeds its own managed DCGM exporter in the `gke-managed-system` namespace. A
self-installed exporter competes with it for the same device.

**Fix.** On GKE, scrape the managed exporter instead of installing your own. Off GKE, where you run the
self-managed GPU Operator, you *do* install your own `dcgm-exporter`; the Operator owns the GPU stack
there. This split is part of why managed GPU is an advantage on GKE: the provider keeps
the GPU observability plumbing working for you.

## GPU Operator DCGM scraping is not implicit

**Symptom.** On an off-GKE cluster, the NVIDIA GPU Operator app is Synced and Healthy, but Prometheus
has no DCGM scrape target from the operator's exporter.

**Cause.** The GPU Operator chart can enable `dcgmExporter` while leaving
`dcgmExporter.serviceMonitor.enabled` false. Assuming the chart default creates a ServiceMonitor leaves
the metrics path invisible even though the operator itself installed cleanly.

**Fix.** In `platform/nvidia-gpu-operator/values.yaml`, set
`dcgmExporter.serviceMonitor.enabled: true`. Prometheus already discovers ServiceMonitors across
namespaces (`serviceMonitorSelectorNilUsesHelmValues: false`), so no separate
`platform/dcgm-metrics` object is rendered in `gpu_stack: operator` mode.

## Hugging Face 429 on cold pull

**Symptom.** Model download fails with HTTP 429 (rate limited) during a cold start, intermittently and
worse when several pods pull at once.

**Cause.** A cluster shares one egress IP, and that IP can trip Hugging Face's rate limits when many
pods (or repeated cold starts) pull weights through it at once.

**Fix.** Pre-stage the weights so serve time never touches Hugging Face. The OCI modelcar bakes the
weights into the image (no pull at all), and the vLLM container runs fully offline with
`HF_HUB_OFFLINE=1`. Cold start then depends only on local image and disk, not on a third-party rate
limit.

## Argo CD reapplies a manual scale-to-zero

**Symptom.** You manually scale a GPU deployment to zero to stop paying for the node, and Argo CD
scales it straight back up within a sync cycle.

**Cause.** `selfHeal` treats your manual `replicas: 0` as drift from the desired state in git and
reconciles it away.

**Fix.** The GPU-serving apps set `ignoreDifferences` on `/spec/replicas` with
`RespectIgnoreDifferences=true` (or stay on manual sync), so Argo CD leaves the replica count alone and
a manual scale-to-zero sticks. In the default single-GPU footprint this is the cost control: the
operator, not the reconciler, decides when the accelerator node is running. (Multi-GPU HA uses the
2-replica RollingUpdate overlay instead; see `serving/overlays/raw-vllm-multi-gpu-ha/`.)

## Coding-assistant tool-calling reliability

**Symptom.** An agentic coding client misbehaves: tool calls are skipped or malformed, and Tabby's
readiness probe fails even though the server is healthy.

**Cause.** Two separate traps. Qwen2.5-Coder with `tool_choice: auto` is unreliable for agentic
clients (the model does not reliably decide to call the tool). Separately, Tabby's health endpoint
sits behind the auth gate, so a naive readiness probe against it gets a 401 and the pod never goes
ready.

**Fix.** Drive tool calls with `tool_choice: required` (or a client-side workaround) rather than
leaving the decision to `auto`. For readiness, probe an unauthenticated path, not the auth-gated health
endpoint.

## LiteLLM SSO licensing cliff

**Symptom.** Wiring SSO into LiteLLM's built-in admin UI works for a handful of users, then hits a
hard cap.

**Cause.** LiteLLM's built-in admin-UI SSO is capped at five users on the free tier; past that it is an
Enterprise feature.

**Fix.** Put SSO at the edge instead of inside LiteLLM. This platform runs Dex plus oauth2-proxy at the
gateway and adds a do-it-yourself self-service key portal that mints virtual keys through the OSS
LiteLLM API. SSO covers everyone at the edge, key issuance stays self-service, and the Enterprise gate
is never in the path.

## Gateway data plane runs in the Gateway namespace, not the controller's

**Symptom.** A gateway-routed app returns `upstream call failed: Connect: deadline has elapsed` even
though the backend pod is Healthy and its HTTPRoute is accepted.

**Cause.** agentgateway splits into a controller in `agentgateway-system` and a per-Gateway data plane
proxy that runs in the Gateway's own namespace. `platform-gateway` is defined in `experience`, so its
data plane pod runs there. A NetworkPolicy that allows ingress only from `agentgateway-system` blocks
the connection, because the data plane, not the controller, opens the upstream hop.

**Fix.** Allow ingress from the namespace where the Gateway is defined. For `platform-gateway` that is
`experience` (see `experience/n8n/manifests/networkpolicy.yaml` and the key portal's
`networkPolicy.fromNamespace`), not `agentgateway-system`. Match the data plane's namespace, not the
controller's.
