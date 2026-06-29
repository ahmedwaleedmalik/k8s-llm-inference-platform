# gpu-smoke

Verifies the GPU stack works end-to-end. Not GitOps-synced — run manually.

```bash
kubectl apply -f job.yaml
kubectl logs -f job/gpu-smoke -n default   # expect nvidia-smi output (L4, driver version)
kubectl delete -f job.yaml                 # node scales back to 0
```

Applying the Job triggers: autoscaler → L4 node → GKE installs the driver + device plugin →
`nvidia-smi` runs. First run is slow (node provision + driver install, several minutes).
