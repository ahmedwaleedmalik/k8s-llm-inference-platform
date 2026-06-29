---
title: "Production HA"
---

The `prod` economic tier (ADR-0029 SR3) turns the single-replica lab into a minimally
highly-available deployment. This guide documents what the tier changes and how to validate each HA
behavior against a live cluster.

## Enable the prod tier

Set `profile: prod` in `environments/ai-dev/config.yaml`, then run `make resolve-profile` (also chained
by `make resolve-groups`). The resolver `scripts/resolve-profile.sh` renders the HA overlays; runtime
manifests stay verbatim and the overlays layer on top (ADR-0031). Do not hand-edit the generated files
(`clusters/ai-dev/litellm-profile.generated.yaml`, `platform/litellm/db/kustomization.yaml`); re-run the
resolver instead.

Compared with the `cost` and `dev` defaults, `prod` turns on:

| Component | cost / dev | prod |
|---|---|---|
| LiteLLM replicas | 1 | 2 |
| Redis budget and rate cache | off | on (shared state across replicas) |
| Budget on DB outage | fail-open (`allow_requests_on_db_unavailable: true`) | fail-closed (`false`) |
| CloudNativePG instances | 1 | 3 (one primary, two streaming replicas) |
| Postgres backups | none | daily VolumeSnapshot ScheduledBackup |
| PodDisruptionBudgets | none | LiteLLM proxy and CNPG primary |

## Validate

### CNPG primary failover (automatic, no data loss)

Note the current primary, then delete its pod to force a failover:

```sh
kubectl -n litellm get pods -l cnpg.io/cluster=litellm-pg -L cnpg.io/instanceRole
kubectl -n litellm delete pod <primary> --wait=false
kubectl -n litellm get cluster litellm-pg -o jsonpath='{.status.phase} {.status.currentPrimary}'
```

CloudNativePG moves through `Failing over` to `Cluster in healthy state`, promotes a streaming replica
to primary, and rejoins the old primary as a replica. The `litellm-pg-rw` Service repoints to the new
primary automatically, so LiteLLM reconnects with no config change. To prove no committed data was lost,
write a probe row before the failover and read it back from the new primary afterward.

Caveat: replication is asynchronous (`pg_stat_replication.sync_state = async`), so a sudden primary loss
can drop transactions that were committed but not yet shipped to a replica (nonzero RPO). The failover
itself stays consistent. Configure synchronous replication in the Cluster spec if you need zero RPO.

### PodDisruptionBudget blocks disruptive drains

The CNPG primary PDB allows zero voluntary disruptions, so a node drain cannot evict the primary until
CloudNativePG has failed over first. Confirm by attempting an eviction through the API:

```sh
kubectl create --raw "/api/v1/namespaces/litellm/pods/<primary>/eviction" \
  -f - <<<'{"apiVersion":"policy/v1","kind":"Eviction","metadata":{"name":"<primary>","namespace":"litellm"}}'
# Expected: TooManyRequests: Cannot evict pod as it would violate the pod's disruption budget
```

The LiteLLM proxy PDB sets `minAvailable: 1` across its two replicas, so one replica can be evicted (a
drain proceeds) while the second stays protected.

### Budget enforcement across replicas

With two LiteLLM replicas sharing the Redis cache, a per-key budget is enforced consistently regardless
of which replica serves the request. `make verify` exercises this end to end: an over-budget virtual key
returns HTTP 429 on the keyed path.
