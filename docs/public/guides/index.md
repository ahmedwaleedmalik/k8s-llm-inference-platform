---
title: "Guides"
---

Task-focused runbooks for operating the platform after it is installed. Start with the area that is
failing or changing; each guide points back to the manifests and decisions that own the behavior.

<CardGroup cols={2}>
  <Card title="GPU & scheduling" icon="activity" href="/guides/gpu-debugging">
    Debug GPU visibility, pending workloads, queue admission, and KEDA queue-depth autoscaling.
  </Card>
  <Card title="Serving" icon="cpu" href="/guides/vllm-serving">
    Run raw vLLM, compare KServe, package OCI modelcars, and change the served model.
  </Card>
  <Card title="Routing & gateway" icon="waypoints" href="/guides/inference-gateway">
    Route requests through LiteLLM, the inference gateway, tenant budgets, and guardrails.
  </Card>
  <Card title="Experience apps" icon="app-window" href="/guides/n8n">
    Run n8n, the API key portal, Open WebUI, Tabby, and coding-assistant surfaces.
  </Card>
  <Card title="Platform & ops" icon="shield-check" href="/guides/staged-bring-up">
    Wire secrets, SSO, security controls, staged bring-up, HA validation, and teardown.
  </Card>
  <Card title="Benchmarking" icon="chart-line" href="/guides/benchmarking">
    Measure latency, throughput, saturation, and serving regressions with GuideLLM.
  </Card>
</CardGroup>
