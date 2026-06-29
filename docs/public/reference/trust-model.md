---
title: "Trust model"
---

The single assumption that settles the platform's posture. Most "why isn't this isolated?" questions
resolve to one decision: **the platform assumes cooperative, trusted internal tenants, not hostile or
adversarial multi-tenancy.** Several posture choices that would look like gaps under an adversarial model
are deliberate and acceptable under this one. They are stated here so the assumption is explicit rather
than implied.

> The enforcement controls that ride on this assumption: [Security posture](/reference/security).

## The assumption

Tenants are a small set of internal teams who are trusted not to attack each other. The boundaries the
platform enforces (virtual keys, budgets, GPU quota) are **economic and access controls**, not hardened
security partitions. LiteLLM is the tenancy boundary in the sense of *who pays for what and who may call
the endpoint*; it is not a defense against a tenant who is actively trying to read another tenant's data
or starve another tenant's GPU.

This is the correct tier for a single-cluster reference deployment shared by cooperating teams. It is the
wrong tier for serving untrusted or external tenants on shared hardware. The difference is not a bug list;
it is a different deployment profile, and the triggers for moving up a tier are stated below.

## What this settles

**Prefix / KV-cache sharing across tenants is acceptable.** vLLM V1 automatic prefix caching is on by
default and the backend is a single shared vLLM instance, so there is no tenant-scoping of the prefix
cache (`serving/raw-vllm/deployment.yaml` sets no `--disable-prefix-caching` flag and no per-tenant
prefix scorer). Inference-aware routing (GIE / EPP) co-locates same-prefix requests onto the same replica
precisely to hit that shared cache. Under a trusted tier this is a throughput win. Under an adversarial
tier the same co-location is a cross-tenant timing and content side channel, so it would have to be
disabled or scoped. The platform accepts the sharing deliberately, on the trusted-tenant assumption.

**GPU isolation is soft, by design.** There is no hard MIG partitioning (the lab's GPU class does not
support MIG, and MIG is not configured). GPU sharing, where it exists, is rationed by Kueue quota and
would extend to time-slicing, neither of which gives VRAM isolation: time-slicing interleaves work on one
GPU with no memory boundary, so a noisy neighbor can degrade a co-resident workload. GPU sharing is a
**fairness and packing** mechanism, not a security boundary. (Time-slicing itself is deferred, see the
[roadmap](/reference/roadmap); today the baseline is one model per GPU.)

**Kueue is quota, not isolation.** Kueue suspends GPU jobs until their queue has free quota
and admits them in FIFO order. It enforces fair-share rationing of a scarce resource; it does not isolate
one tenant's workload from another's. Admission is opt-in: a GPU pod without the
`kueue.x-k8s.io/queue-name` label bypasses quota entirely, which is what the optional SR2 Kyverno control
closes when more than one tenant queue or GPU flavor exists.

## What moving up a tier requires

| Assumption changes to | Then this becomes required | Mechanism |
|---|---|---|
| Untrusted tenants may attempt cross-tenant data leakage | Disable or tenant-scope prefix/KV-cache sharing | Turn off automatic prefix caching, or partition the cache per tenant; remove prefix-based co-location |
| Untrusted tenants share GPU hardware | Hard GPU partitioning | MIG (on a MIG-capable GPU) or dedicated node pools per sensitive tenant, not time-slicing |
| More than one team or GPU flavor shares the cluster | Force the quota and budget paths | SR1 NetworkPolicy + SR2 Kyverno, shipped dormant and enabled by flag |
| Tenant workloads are mutually distrusting | Network and namespace isolation enforced, not logical | Per-tenant namespace + ResourceQuota + RBAC + default-deny NetworkPolicy |

## The principle

The trust tier is a configuration, not a constraint baked into the architecture. The economic and access
controls (keys, budgets, quota) exist from the start; the hard isolation controls (cache scoping, MIG or
dedicated pools, enforced network and namespace partitions) are deferred with stated triggers because a
cooperative single-cluster deployment does not need them. Naming the assumption is the honest position: the
platform is secured to the trusted-internal-tenant tier on purpose, and the [roadmap](/reference/roadmap) records
the work that raises it.
