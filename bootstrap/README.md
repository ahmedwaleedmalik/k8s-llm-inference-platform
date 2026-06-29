# bootstrap

The one-time GitOps entrypoint. It installs Argo CD; after that, Argo CD reconciles everything from
Git, so the cluster's whole state is declared in this repo rather than applied by hand.

## Prerequisite: point the repo at your cluster

This repo talks only to its own `./kubeconfig` (gitignored), never your global current context, so a
context switch elsewhere can't redirect a deploy. Generate it once; every step below validates against it:

```bash
gcloud container clusters get-credentials <name> --region <r> --project <p> --kubeconfig=$PWD/kubeconfig
# bring-your-own cluster: cp /path/to/kubeconfig ./kubeconfig   (or export CLUSTER_KUBECONFIG=/path)
make require-kube     # prints + validates kubeconfig / context / server
```

## Flow

1. **Install Argo CD**:

   ```bash
   make bootstrap        # = ./bootstrap/install.sh
   ```

2. **Give Argo CD access to this (private) repo**, once, so it can sync the app-of-apps:

   ```bash
   export ARGOCD_REPO_PAT=<fine-grained PAT, Contents: Read-only>
   make argocd-repo
   ```

   (When the repo is public, skip this step: Argo CD reads a public repo with no credential.)
3. **Apply the app-of-apps roots**, so Argo CD manages itself and all child apps for the chosen
   profile:

   ```bash
   make root             # default PROFILE=platform (base only); see ADR-0027 for serving|llm-gateway|full
   ```

## Self-management

After step 3, `clusters/ai-dev/catalog/platform-core/argo-cd.yaml` makes Argo CD manage its own install from
`bootstrap/argo-cd/values.yaml` (same pinned chart). Edit Argo CD config there, commit, and it self-syncs.

`bootstrap/argo-cd/values.yaml` is the single source of truth for Argo CD config, used by both the
initial `install.sh` and the self-managing Application.
