---
title: "Kubernetes LLM Platform"
---

Run an authenticated, OpenAI-compatible LLM endpoint on Kubernetes with GitOps, GPU quota,
inference-aware routing, and tenant budgets.

This is an infrastructure reference, not a chatbot application. The model server is one workload in
a platform that is designed to be forked, audited, and moved across GPU-capable clusters.

## Stack in one picture

![Kubernetes LLM platform planes showing GitOps, experience and automation, tenant edge, routing, serving, GPU platform, identity and secrets, observability, and cloud substrate](assets/diagrams/platform-planes.png)

The hard boundary is the point: OpenTofu owns the cloud substrate; Argo CD owns everything inside
Kubernetes. To change clouds, re-solve the substrate, not the platform.

## What it proves

| Proof point | Where to look |
|---|---|
| vLLM and KServe can serve the same OpenAI-compatible model path. | [Serving layers compared](/architecture/serving-layers) |
| LiteLLM owns tenant keys, budgets, spend, and the public `/v1` facade. | [LiteLLM guide](/guides/litellm) |
| Gateway API plus GIE routes by inference signals instead of plain HTTP load balancing. | [Inference gateway guide](/guides/inference-gateway) |
| Kueue and KEDA keep GPU admission, quota, and queue-depth autoscaling explicit. | [GPU debugging guide](/guides/gpu-debugging) |
| Benchmarks tie latency, throughput, GPU use, and KV-cache pressure to the same run. | [Benchmark results](/benchmarks) |

## Why it exists

Self-hosting LLM inference well is not "run vLLM in a pod." A production endpoint has to solve GPU
scheduling and quota, inference-aware routing, per-tenant keys and budgets, keyless secrets,
scale-to-zero economics, model delivery, and observability. It also has to stay portable instead of
welding itself to one cloud's managed services. Each of those is a decision, and most reference
setups either skip them or hard-code them to a single provider.

## Operating model

The platform packages the open-source control plane behind one forkable repo: vLLM, KServe, Gateway
API with the Gateway Inference Extension, Kueue, KEDA, LiteLLM, External Secrets, and Argo CD. A
hard line separates two halves:

**Substrate** is the cluster, node pools, identity, and GPU drivers. Infrastructure-as-code owns it,
and it is swapped per cloud.

**Platform** is everything inside Kubernetes. GitOps owns it, and it stays identical across clouds.

That separation is the portability story.

A platform you can fork and run on any GPU-capable Kubernetes cluster: GKE today, with Hetzner and
bring-your-own cluster paths documented. It scales from a single scale-to-zero L4 to a multi-tenant,
highly available deployment without changing the in-cluster architecture.

## Start by intent

| Intent | Start here |
|---|---|
| See the system boundary and request path. | [Architecture](/architecture) |
| Bring up a fork from zero. | [Get started](/getting-started) |
| Operate a running stack. | [Guides](/guides) |
| Check measured serving behavior. | [Benchmark results](/benchmarks) |
| Look up terms, targets, models, and secrets. | [Reference](/reference) |
| Understand why the stack is shaped this way. | [Design rationale](/decisions) |
