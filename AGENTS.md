# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

A GitOps-managed, GKE-first **LLM inference platform on Kubernetes**. There is almost no application
code; the repo is OpenTofu (cloud substrate) + Argo CD-reconciled Kubernetes manifests / Helm values.
The deliverable is the declarative stack itself. `CONTEXT.md` is the canonical glossary;
`docs/public/decisions/` holds the "why". Read those before making non-trivial changes.

## The two hard boundaries (most important architecture fact)

1. **Substrate vs in-cluster** (ADR-0028). The cloud layer (GKE cluster, node pools, Workload
   Identity, IAM, Artifact Registry) is owned by **OpenTofu** under `infra/gke/terraform/` and is
   **never** touched by Argo. Everything *inside* Kubernetes (controllers, CRDs, workloads, secret
   sync) is owned by **Argo CD** via GitOps and is **never** managed by OpenTofu. Do not cross this line.
2. **Secret values never enter git or IaC state** (ADR-0011). External Secrets Operator materializes
   K8s Secrets from GCP Secret Manager. `config.yaml` holds only non-secret fork knobs (domains, IDs,
   hostnames).

## Selection model (read before touching `clusters/ai-dev/`)

Three orthogonal axes control what deploys (ADR-0027, ADR-0031):

- **Profile / staging** sets which *layers* you apply: `make root PROFILE=platform|serving|llm-gateway|full`.
  Layers are cumulative: `platform | serving | routing | llm-gateway | experience | demos`.
- **Selection / features** sets which *capability groups* exist, driven by `environments/ai-dev/config.yaml`
  `features:`. Edit it, then `make resolve-groups` regenerates `clusters/ai-dev/groups.generated.yaml`.
  `-core` groups are always on. Disabling a group cascades a clean delete.
- **Bring-up**: each app's own `manual-sync` policy (a manual-sync app is created but not auto-deployed).

`clusters/ai-dev/catalog/<group>/` holds **only** plain `kind: Application` YAML (a `directory.recurse`
source, so no `Chart.yaml`/`kustomization.yaml` there). Actual Helm values / manifests live under the
top-level `platform/ serving/ routing/ workloads/` dirs that those Applications point at.

`config.yaml` is also the **single source** of `repoURL` + GCP `projectID`; `make fork-init` propagates
them across the repo. `*.generated.yaml` files are build artifacts; regenerate via the
resolver scripts, don't hand-edit.

## Request path (top to bottom)

LiteLLM (tenant edge: virtual keys, budgets, spend ledger; the tenancy boundary, ADR-0013)
→ GIE / Gateway API Inference Extension on agentgateway (inference-aware routing: InferencePool + EPP, ADR-0005)
→ vLLM (default, OpenAI-compatible) or KServe ISVC (managed-lifecycle alternative, ADR-0006)
→ GPU platform: GKE-managed NVIDIA driver/DCGM, Kueue quota admission (ADR-0002), KEDA autoscaling on
`vllm:num_requests_waiting` (ADR-0014).

## Common commands

Everything is driven by the root `Makefile` (`make help` lists all targets). Workflow order:

```bash
make bootstrap            # install Argo CD on current kube-context (pinned chart)
make resolve-groups       # config.yaml features: → groups.generated.yaml (chains resolve-profile + resolve-secret-store + resolve-gpu + resolve-guardrails)
make root                 # apply AppProject + per-layer ApplicationSets for PROFILE (default platform)
make doctor PROFILE=…     # validate local config + live cluster prereqs
make wait PROFILE=…       # wait for auto-sync apps to be Synced+Healthy
make verify               # end-to-end pass/fail check (GitOps + economics + budget-429 + serving + edge/SSO)
```

Cloud substrate (paid, OpenTofu): `make tf-fmt | tf-init | tf-validate | tf-plan | tf-apply | tf-destroy`.
Cost control: `make pause` (DESTRUCTIVE: releases LBs, destroys substrate; GSM secrets survive) /
`make resume`. Serving on a real GPU: `make vllm-up` / `vllm-down` / `vllm-smoke` / `bench` /
`bench-guidellm` / `gpu-smoke`. Docs (Mintlify): `make docs-serve` (localhost:3000) / `make docs-build` (broken-link check).

`CLUSTER` (default `ai-dev`) and `PROFILE` (default `platform`) are overridable on any target.

## Pre-push checks (mirror CI; run these locally before pushing)

CI (`.github/workflows/ci.yml`) is the gate. Reproduce each job locally:

- **shellcheck** `scripts` at severity=error.
- **OpenTofu**: `make tf-fmt` (=`tofu fmt -check -recursive`), then `tf-init -backend=false` + `tf-validate`,
  then `tests/gke-terraform-dependencies/run.sh` (asserts the ESO Workload-Identity binding depends on the GKE cluster in the plan graph).
- **manifests**: for every `kustomization.yaml`, `kustomize build | kubeconform -strict -ignore-missing-schemas`.
- **selection / ownership tests**: run each `tests/*/run.sh` (resolver golden-file diffs plus
  `kserve-app-ownership`; needs `pyyaml`). `gke-terraform-dependencies` runs in the OpenTofu job above.
- **tflint** on both `infra/gke/terraform` and `infra/hetzner/terraform`.
- **secret-scan** (gitleaks), **checkov**/**trivy config** (k8s).

Docs prose is linted by **Vale** (`.vale.ini` + `styles/`) over `docs/public`; `lint-docs.yml`
fails on error. Published docs use enterprise/product voice and **zero em dashes**. When drafting
docs, also follow `docs/STYLE.md` (local authoring guide) for the judgment rules Vale can't check:
every claim cites a file, flag, number, or observed output; no slop.

## Conventions (from CONTRIBUTING.md)

- **Declarative only.** No imperative cluster mutation as source of truth; if it isn't in git, it
  doesn't exist.
- **Pin everything.** Chart versions, image tags (prefer `@sha256` digests), CRD versions. Never `:latest`.
- **One capability per change.** A change ships its proof: manifests + an ADR (if a decision was made,
  `docs/public/decisions/NNNN-*.md`) + a guide (`docs/public/guides/`, if operational) + a benchmark/smoke result where relevant.
- **Conventional Commits**, scoped where useful (`fix(kserve): …`). Keep messages concise.
- New components go under the matching top-level dir with a child `Application` in
  `clusters/ai-dev/catalog/<group>/`, enabled via `config.yaml features:`.
