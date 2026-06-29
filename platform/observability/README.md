# observability

Cluster metrics and dashboards via [kube-prometheus-stack](https://github.com/prometheus-community/helm-charts/tree/main/charts/kube-prometheus-stack)
(chart `86.2.3`, Prometheus Operator `v0.91.0`). Prometheus is the scrape target every
inference component (DCGM exporter, vLLM, Gateway API Inference Extension) feeds into.

## What's enabled
- Prometheus (7-day retention, 10Gi PVC), Grafana, kube-state-metrics, node-exporter.
- ServiceMonitor/PodMonitor discovery across **all** namespaces, so workloads ship
  their own monitors without a release label.
- Grafana dashboard sidecar watches all namespaces for `grafana_dashboard=1` ConfigMaps.

## Trimmed for a dev cluster
- Alertmanager **off** — no paging target yet.
- Managed-control-plane scrape jobs (etcd, scheduler, controller-manager, kube-proxy)
  **off** — those endpoints aren't reachable on GKE and would only show as down.

## Alerting is deliberately deferred
The ADR-0003 inference SLOs (TTFT/ITL/E2E p95, error rate) are **documented and dashboarded,
not enforced**: there is no `PrometheusRule` and Alertmanager is disabled on purpose. On a
single-GPU, single-model dev/reference cluster a breach rule would fire to a nonexistent paging
target, and the only honest remediation (`num_requests_waiting > 0` ⇒ shed/queue, don't scale
pods on one GPU) isn't an automated action yet. Breach detection is by dashboard + the
benchmark harness. PRODUCT TRIGGER for adding burn-rate `PrometheusRule`s + enabling
Alertmanager = first multi-replica / multi-model serving (per-model SLOs), per ADR-0003.

## SSO (Dex OIDC)
Grafana federates to Dex (`generic_oauth`, additive, so the admin login above still works). Role map:
`admin@<domain>` → Admin, everyone else → Viewer. The client secret is shared with the Dex `grafana`
staticClient (`platform/dex/values.yaml`), ESO-synced into the `grafana-oidc` Secret and injected via
`envValueFrom` → `GF_AUTH_GENERIC_OAUTH_CLIENT_SECRET` (resolved by `$__env{...}` in `grafana.ini`).

One-time backend seed (see `manifests/externalsecret.yaml`):
```bash
openssl rand -hex 32 | tr -d '\n' | gcloud secrets create dex-grafana-client-secret --data-file=- --project ai-lab
```
Redirect URI: `https://grafana.<domain>/login/generic_oauth`.

## Verify
```bash
kubectl -n monitoring get pods
kubectl -n monitoring port-forward svc/observability-grafana 3000:80   # http://localhost:3000
kubectl -n monitoring get secret observability-grafana \
  -o jsonpath='{.data.admin-password}' | base64 -d; echo               # admin password
```
