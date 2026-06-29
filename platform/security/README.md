# security group — enforcement (ADR-0029)

The `security` capability group turns the platform's *logical* controls into *enforced* ones. It is a
platform-layer optional group, **OFF by default** (`features.security: false`). A single-tenant lab
never hits these gaps, so they ship dormant and pull forward with the multi-tenancy / governance work.

| App | SR | What it does |
|-----|----|--------------|
| `network-policies` | SR1 | Default-deny + allow-trusted ingress on `serving` and `inference`, so **LiteLLM is the sole authorized caller** of the model servers + GIE gateway. Tenant pods can only reach LiteLLM → the budget/key path is no longer network-bypassable. |
| `kyverno` | SR2 | Kyverno admission engine (chart 3.8.1). **Install note:** the chart's `clusterpolicies`/`policies` CRDs exceed Argo CD's client-side apply annotation limit (256 KB), so a first sync stalls with `metadata.annotations: Too long`. App carries `ServerSideApply=true`, but if Argo still applies them client-side, bootstrap once: `helm template kyverno kyverno/kyverno --version 3.8.1 --include-crds \| kubectl apply --server-side`. Pre-create the `kyverno` namespace to avoid the RBAC-before-namespace race. |
| `kyverno-policies` | SR2 | `ClusterPolicy` rejecting GPU pods that lack `kueue.x-k8s.io/queue-name` in Kueue-managed namespaces → unlabeled pods can't bypass Kueue quota. |

## Dependencies / enablement notes

- **Apply the `serving` + `llm-gateway` layers too.** The NetworkPolicies target the `serving` and
  `inference` namespaces; with only the platform layer up they stay dormant (selfHeal retries until
  the namespaces exist).
- **NetworkPolicy enforcement needs a capable CNI.** On GKE that means **Dataplane-V2**, flipped at
  cluster creation (ADR-0028). Retrofitting can force node recreation. Without it the policies are
  authored-but-not-enforced. Native `networking.k8s.io/v1` keeps them portable (Calico/Cilium/Antrea).
- **SR2 scope is opt-in per namespace.** The ClusterPolicy only matches namespaces labelled
  `llm-platform/kueue-managed: "true"`. The platform's own model servers (`serving`) are operator-managed
  and carry no queue-name, so they are deliberately out of scope. Label tenant namespaces to gate them:
  `kubectl label ns team-a llm-platform/kueue-managed=true`.

## Validate (live)

- SR1: a tenant pod reaches `litellm` but `curl` to `inference-gateway.inference.svc` / a `serving`
  Service is refused.
- SR2: a GPU pod without `kueue.x-k8s.io/queue-name` in a labelled namespace is denied at admission.

Validated on a GKE Dataplane-V2 cluster: SR1 — a pod in `default` (untrusted) timed out
to `embeddings.serving.svc`; a pod in `monitoring` (trusted) got HTTP 200. SR2 — a GPU pod without
`kueue.x-k8s.io/queue-name` in an `llm-platform/kueue-managed=true` namespace was rejected by the
`require-kueue-queue-name` policy; the same pod with the label, and a non-GPU pod, were admitted.
