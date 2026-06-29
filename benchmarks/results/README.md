# Recorded benchmark artifacts

Raw harness output, one directory per run, named `<date>-<gpu>-<model>/`:

```
benchmarks/results/2026-06-26-t4-qwen2.5-0.5b/report.json
```

`make bench-guidellm` writes the report in the pod and emits the trimmed JSON to the Job log between
`GUIDELLM_REPORT_BEGIN`/`GUIDELLM_REPORT_END` markers (kubectl cp cannot reach a completed pod). Copy
it here with:

```sh
kubectl -n serving logs job/guidellm-bench \
  | sed -n '/GUIDELLM_REPORT_BEGIN/,/GUIDELLM_REPORT_END/p' | sed '1d;$d' \
  > benchmarks/results/<date>-<gpu>-<model>/report.json
```

The committed JSON drops the per-request logs (multi-MB) but keeps every aggregated metric
(p50/p95/p99 TTFT+ITL, per-rate success/error counts) the summary table in
[`../README.md`](../README.md) is derived from; cost/hr is computed from `GPU_COST_PER_HR`. Keep the
JSON committed so the recorded tables stay reproducible.
