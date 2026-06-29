# external-secrets

Runtime secrets via **External Secrets Operator (ESO)** → **GCP Secret Manager**. On GKE the store
authenticates by **Workload Identity** (no stored credential); off-GKE it falls back to a static
service-account key. Secret *values* live only in the backend; git holds only references.

## Files

- `values.yaml` — ESO operator Helm values (binds the controller KSA to a GCP service account).
- `config/clustersecretstore.yaml` — the backend binding (`secret-store`). **GENERATED** by
  `scripts/resolve-secret-store.sh` from `secret_store_auth` in `environments/<env>/config.yaml` — do
  not edit; run `make resolve-secret-store` (or `make resolve-groups`, which chains it).
- `example-externalsecret.example.yaml` — the per-secret pattern (copy, don't apply as-is).

## Store auth (config knob)

`secret_store_auth:` in `config.yaml` selects how the store authenticates — orthogonal to the backend:

- `workload-identity` (default) — keyless GKE Workload Identity (ESO controller KSA → GSA).
- `sa-key` — static SA JSON key in Secret `secret-store-key` (off-GKE forks; same backend, same
  identical ExternalSecrets, only the auth path changes).

Generated as a committed artifact (mirrors `groups.generated` / `litellm-profile.generated`) so the
swap is GitOps-native: the rendered store is the single source of truth ESO + Argo agree on, instead
of a manual `kubectl` override that Argo self-heal would re-assert (the Hetzner proof).

## One-time GCP setup (Workload Identity)

```bash
PROJECT=ai-lab; ZONE=us-central1-a; CLUSTER=ai-dev
GSA=external-secrets@${PROJECT}.iam.gserviceaccount.com

# 0. Enable Workload Identity on the cluster + node pool (currently OFF)
gcloud container clusters update $CLUSTER --zone $ZONE --project $PROJECT \
  --workload-pool=${PROJECT}.svc.id.goog
gcloud container node-pools update default-pool --cluster $CLUSTER --zone $ZONE --project $PROJECT \
  --workload-metadata=GKE_METADATA

# 1. GCP service account + Secret Manager read access
gcloud iam service-accounts create external-secrets --project $PROJECT
gcloud projects add-iam-policy-binding $PROJECT \
  --member="serviceAccount:${GSA}" --role="roles/secretmanager.secretAccessor"

# 2. Bind the ESO Kubernetes SA (external-secrets/external-secrets) to the GSA
gcloud iam service-accounts add-iam-policy-binding $GSA --project $PROJECT \
  --role="roles/iam.workloadIdentityUser" \
  --member="serviceAccount:${PROJECT}.svc.id.goog[external-secrets/external-secrets]"
```

## Off-GKE setup (`secret_store_auth: sa-key`)

Off-GKE there is no metadata-server WI, so the store reads a static SA JSON key from Secret
`secret-store-key`. Simpler to reproduce than Workload Identity Federation (no WIF pool, no JWKS
upload) at the cost of one rotatable credential. Set `secret_store_auth: sa-key` in `config.yaml`,
run `make resolve-secret-store`, and seed the key once:

```bash
gcloud iam service-accounts create eso-offgke --project ai-lab
gcloud projects add-iam-policy-binding ai-lab \
  --member serviceAccount:eso-offgke@ai-lab.iam.gserviceaccount.com \
  --role roles/secretmanager.secretAccessor
gcloud iam service-accounts keys create sa-key.json \
  --iam-account eso-offgke@ai-lab.iam.gserviceaccount.com
kubectl -n external-secrets create secret generic secret-store-key --from-file=sa-key.json=sa-key.json
```

Then delete the local `sa-key.json`. Pin ESO >= 2.6.0.

The auth choice is about reproducibility, not cloud decoupling: GSM is still a GCP
dependency regardless of auth. True off-cloud independence means swapping the *backend* (see fork note below).

## Add a secret (the everyday flow)

1. Put the value in the store: `echo -n "<value>" | gcloud secrets create <name> --data-file=- --project ai-lab`
2. Add an `ExternalSecret` (see the example) in the layer that needs it. Done — ESO syncs it.

## Fork note

Swap the provider in `scripts/resolve-secret-store.sh` to any backend (AWS SM, Azure KV, Vault/OpenBao,
or `fake` for local); `ExternalSecret`s stay identical. See ADR [`0011`](../../docs/public/decisions/0011-secrets-and-config-strategy.md),
including the no-ESO escape hatch for forkers who don't want the dependency.
