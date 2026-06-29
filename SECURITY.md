# Security Policy

This is a self-hostable reference platform for LLM inference on Kubernetes. It is operated by the
forker on their own infrastructure, so "security" has two distinct meanings, kept separate below.

## Reporting a vulnerability

Report suspected vulnerabilities privately. Do not open a public issue for a security problem.

- Use GitHub private vulnerability reporting (the repository's **Security** tab, "Report a
  vulnerability"). This opens a private advisory visible only to the maintainers. Include a
  description, affected paths, and reproduction steps.

Expect an acknowledgement within a few days. Fixes land on `main` and, where relevant, are noted in
a published GitHub Security Advisory. There is no embargo program and no bounty.

## What is in scope

Issues in the platform's own configuration and code: the manifests, Helm values, OpenTofu, scripts,
and CI in this repository. Examples that are in scope: a secret committed to git, a manifest that
exposes an unauthenticated path that should be keyed, a privilege escalation in a shipped workload,
or a supply-chain gap such as an unpinned image.

Out of scope: vulnerabilities in upstream projects this platform integrates (vLLM, KServe, llm-d,
Kueue, Argo CD, External Secrets, Kyverno, and similar). Report those to their respective projects.
Also out of scope: issues that only arise from a forker's own modifications or their cluster's
configuration.

## Security posture (read this first)

Much of what might look like a vulnerability is a deliberate, documented posture decision. Before
reporting, check the two posture documents, which state plainly what is enforced and what is
intentionally deferred with a trigger:

- [Security posture](docs/public/reference/security.md): what is enforced (secrets, model
  auth, edge TLS, the optional NetworkPolicy and Kyverno controls) and what is deliberately deferred.
- [Trust model](docs/public/reference/trust-model.md): the load-bearing assumption is
  cooperative, trusted internal tenants, not hostile multi-tenancy. Prefix and KV cache sharing,
  soft GPU isolation, and quota-not-isolation are deliberate under that tier. They are the wrong
  posture for serving untrusted tenants on shared hardware, which is a different deployment profile.

A report that an intentionally deferred control is absent is not a vulnerability. A report that an
enforced control can be bypassed is.

## Hardening defaults

Shipped workloads run under the Kubernetes restricted Pod Security baseline (non-root, dropped
capabilities, read-only root filesystem, seccomp `RuntimeDefault`) and all images are digest-pinned.
The checkov and trivy configuration scans are enforcing gates in CI.
