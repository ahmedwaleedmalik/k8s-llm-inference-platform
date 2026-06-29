# dcgm-metrics

DCGM GPU telemetry into the in-cluster Prometheus (kube-prometheus-stack).

The scrape target is **rendered from `config.yaml` `gpu_stack`** by `scripts/resolve-gpu.sh` (run via
`make resolve-groups`), so it follows the GPU stack instead of being hand-edited (see
[ADR-0001](../../docs/public/decisions/0001-gpu-operator-vs-managed.md)):

- `gpu_stack: gke-managed` (default) — GKE runs a per-GPU-node `dcgm-exporter` (namespace
  `gke-managed-system`) with an embedded DCGM engine and pod→GPU attribution. A second, self-run
  embedded exporter conflicts with it (the NVIDIA `dcgm-exporter` chart was tried and crashed on GKE
  for this reason), so we **scrape GKE's exporter** via a `PodMonitor`. Rendered to
  `podmonitor.generated.yaml` (selects `gke-managed-system` pods labelled
  `app.kubernetes.io/name=gke-managed-dcgm-exporter`, port `metrics` / 9400).
- `gpu_stack: operator` — the NVIDIA GPU Operator ships its **own** `dcgm-exporter` ServiceMonitor
  (chart default), which the in-cluster Prometheus discovers cluster-wide
  (`serviceMonitorSelectorNilUsesHelmValues: false`). This dir renders an **empty** kustomization (no
  duplicate scrape object). The same `DCGM_FI_DEV_*` metric names feed the Grafana GPU dashboard either
  way.
- `gpu_stack: none` — empty kustomization (no GPU metrics; CPU-only clusters).

`kustomization.yaml` + `podmonitor.generated.yaml` are **build artifacts**; regenerate with
`make resolve-gpu`, do not hand-edit.

Metrics (`DCGM_FI_DEV_*`: util, FB mem, temp, power, DCP profiling) feed the Grafana GPU dashboard
shipped under `dashboards/`.
