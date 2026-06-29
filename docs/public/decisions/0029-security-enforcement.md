---
title: "ADR-0029: Security enforcement: force the budget path and fail closed"
---

**Status:** Accepted
**Date:** 2026-06-20

## Context

An independent architecture review surfaced three enforcement gaps that are invisible on the happy path
but undermine the platform's economic and quota controls the moment more than one team shares the cluster.
Each is a control that exists *logically* (virtual keys and budgets in LiteLLM ([ADR-0013](/decisions/0013-gateway-layering)), GPU quota in
Kueue ([ADR-0002](/decisions/0002-kueue-quota-admission))) but is *bypassable*, because nothing forces traffic and workloads to actually pass
through it. These are product-grade hardening, not lab blockers: a single-tenant lab never hits them. They
must land before any multi-team or public-tenant claim.

## Decision

Adopt all three. Each is track-with-trigger, planned for the multi-tenancy and governance work, with
the pull-forward triggers noted.

### SR1: Force the budget/quota path with NetworkPolicy

Today there is zero NetworkPolicy in the repo, so any pod can reach the inference gateway / raw vLLM
directly and bypass LiteLLM virtual keys and budgets entirely: the economic control plane is
network-bypassable.

Decision: **default-deny + explicit-allow**, so the LiteLLM proxy (matched by namespace + ServiceAccount)
is the *sole* authorized caller of the serving backends; tenant namespaces cannot reach vLLM or the gateway
directly.

**Policy API = native `networking.k8s.io/v1` NetworkPolicy, not `CiliumNetworkPolicy` CRDs.** Native
policies are portable across any compliant CNI (Calico, Cilium, Antrea, GKE Dataplane-V2), so a fork is
never forced onto Cilium: it only needs *a* NetworkPolicy-enforcing CNI. The **enforcement engine** is a
separate, per-substrate choice: on GKE enable Dataplane-V2 (Cilium-backed, but it enforces the native API,
no CRD coupling); on self-managed clusters the operator runs Calico or Cilium. Drop to `CiliumNetworkPolicy`
only if L7/DNS-aware rules later prove necessary, and keep that optional and additive.

Substrate note: enabling Dataplane-V2 on an existing GKE cluster may force recreation, so flip it at the IaC
cluster-creation step ([ADR-0028](/decisions/0028-iac-cloud-substrate)) rather than retrofitting. SR1 is a pull-forward candidate alongside SSO
(both gate the multi-team claim).

Validate: a tenant pod reaches LiteLLM, but `curl` to the inference gateway / vLLM is refused.

### SR2: Gate GPU admission so unlabeled pods can't bypass Kueue quota

Kueue admission is opt-in: only pods carrying `kueue.x-k8s.io/queue-name` are admitted or suspended
([ADR-0002](/decisions/0002-kueue-quota-admission)). A GPU pod *without* the label bypasses quota and fair-share entirely.

Decision: a **Kyverno validating policy rejects any pod requesting `nvidia.com/gpu` in a managed namespace
that lacks `kueue.x-k8s.io/queue-name`.** Chosen over Kueue's `manageJobsWithoutQueueName` (too blunt, it
suspends everything) and over a silent mutate-inject (an explicit deny is auditable). Product trigger: more
than one tenant queue, or more than one GPU flavor.

Validate: an unlabeled GPU pod is denied at admission.

### SR3: Fail-closed budget mode as a profile knob

`allow_requests_on_db_unavailable: true` ([ADR-0013](/decisions/0013-gateway-layering)) plus async spend flushing leaks budget two ways:
(a) when Postgres is down, all requests pass un-metered; (b) even with Postgres up, a burst inside the
async-flush window can exceed a cap before spend lands.

Decision: make it a **profile knob** ([ADR-0027](/decisions/0027-deployment-profiles)). cost/dev profiles = `true` (availability-first; the current
lab default). prod profile = `false` (fail-closed) **and** requires CloudNativePG HA (`instances ≥ 3`) plus a
Redis-backed budget/rate cache (cross-replica accuracy + shrinks the burst window). Implementation is deferred to the
HA hardening in the multi-tenancy and governance work.

Validate: a prod-profile request is rejected when the DB is unreachable; budgets bind under burst with Redis.

## Consequences

- The economic control plane (keys/budgets) becomes genuinely *enforced*, not merely present: the
  precondition for any multi-team claim.
- SR1 portability is preserved: native NetworkPolicy keeps the manifests CNI-agnostic; only the GKE
  substrate opts into Dataplane-V2.
- New cluster dependencies at prod scale: a NetworkPolicy-enforcing CNI, Kyverno, Redis, and CNPG HA. These
  are deliberately *not* enabled in the single-tenant lab.
- SR2/SR3 fold into the governance / HA work; SR1 may pull forward with SSO.

**Update: SR1 and SR2 are shipped.** The default-deny + explicit-allow NetworkPolicy (SR1) and the
Kyverno GPU-admission gate (SR2) are in the repo and tested. They ship **default-off** (enabled by a
config flag) so the single-tenant cost footprint does not carry the complexity, not because they are
unbuilt. **SR3 (fail-closed budgets) remains deferred**: it is gated on CloudNativePG HA + a
Redis-backed cache and rides the HA hardening work.

Relates to [ADR-0002](/decisions/0002-kueue-quota-admission) (Kueue admission), [ADR-0005](/decisions/0005-inference-aware-routing) (GIE serving path), [ADR-0011](/decisions/0011-secrets-and-config-strategy) (secrets), [ADR-0013](/decisions/0013-gateway-layering) (LiteLLM
gateway), [ADR-0014](/decisions/0014-autoscaling) (autoscaling profile knobs), [ADR-0027](/decisions/0027-deployment-profiles) (deployment profiles), [ADR-0028](/decisions/0028-iac-cloud-substrate) (IaC / Dataplane-V2
enablement).
