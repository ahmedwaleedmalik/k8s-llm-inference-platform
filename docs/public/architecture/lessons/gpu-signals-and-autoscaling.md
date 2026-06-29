---
title: "GPU signals"
---

Autoscaling an LLM serving tier starts with one question: what signal do you scale on? Most accelerator metrics lie about load, and the obvious request-concurrency proxy is little better. Picking the wrong signal means an autoscaler that never reacts, or reacts to noise.

## GPU utilization is a lying signal

Under PagedAttention, vLLM holds the GPU near 100% utilization at all times, so GPU-util tells you nothing about whether the server is keeping up. In-flight request count is no better: a slow decode keeps concurrency low while the queue behind it grows. vLLM exposes the signal that actually reflects saturation: `vllm:num_requests_waiting`, requests queued but not yet running. Scale on the queue. Use `vllm:kv_cache_usage_perc` (KV-cache pressure) as a secondary trigger, and watch `vllm:num_requests_swapped > 0` as a tripwire for KV-cache thrash, a sign to scale out sooner or cap concurrency.

## KEDA over an HPA + metrics adapter

The mechanism is KEDA, not a raw HPA wired to a Prometheus Adapter. KEDA's Prometheus scaler queries PromQL directly (the ServiceMonitor already lands vLLM metrics in Prometheus) and generates the HPA for the 1→N range under the hood, with no `external.metrics.k8s.io` plumbing to deploy and operate. The primary trigger is `sum(vllm:num_requests_waiting)` as an `AverageValue` (~5 per replica, so desired = `ceil(total_queue / 5)`). The KEDA operator is a small controller-only component with no GPU cost. This is the convergent 2026 vendor default across GKE inference guidance, Red Hat OpenShift AI, and KServe Standard mode.

Knative/KPA was rejected because concurrency and RPS are poor LLM load proxies and it pulls in Knative Serving, heavy for a single hot model. A GPU-util HPA was rejected outright.

## Autoscaling fights a scale-to-zero cost posture

A live ScaledObject *owns* `/spec/replicas`. On a GPU deployment an unpaused `minReplicaCount: 1` pins an accelerator node up 24/7, which both burns money and fights manual bring-up controls. The resolution is to ship the ScaledObject paused (`autoscaling.keda.sh/paused: "true"`): KEDA touches no replicas while paused, so manual `up`/`down` behave as before, and autoscaling becomes a deliberate, session-scoped action rather than always-on.

The replica floor is a per-profile knob, not a fixed default: `min 2` for HA, `min 1` for dev, `min 0` for cost. True scale-to-zero (`min 0`) additionally needs the KEDA HTTP Add-on as a buffering proxy, because the inference gateway returns 503 at zero endpoints, plus node scale-to-zero and acceptance of a multi-minute cold start. That is a separate problem; see [cold start](/architecture/lessons/cold-start).
