---
title: "Model catalog"
---

The models served by the reference deployment, the backend each runs on, and what to know before
serving it. Tenant-facing model names are the LiteLLM aliases (`model_list` in
`platform/litellm/values.yaml`); every model sits behind the same LiteLLM `/v1` facade, virtual keys,
and budgets.

> All local models are validated on a **single L4 (24 GB), scale-to-zero**: the cost-optimized
> single-GPU footprint, not a production SLA. They serve **one at a time** on one GPU
> (memory-bound for the coder tier); concurrent serving needs GPU time-slicing/multi-GPU. Cost figures are
> illustrative per-token prices set so budgets bind, not measured GPU amortization.

## Served models

| Tenant alias | Model | Backend | GPU | Context | Cost (in / out per token) | SLO target | Eval status |
|---|---|---|---|---|---|---|---|
| `qwen-local` | Qwen2.5-0.5B-Instruct | raw-vLLM (+ KServe modelcar) | 1× L4 | 8192 | $0.5 / $1.5 per MTok | Baseline: TTFT p95 < 250 ms, ITL p95 < 20 ms, E2E p95 < 1.5 s (≤128 out) | Benchmarked ([GuideLLM baseline](/benchmarks)) |
| `coder-chat` | Qwen2.5-Coder-7B-Instruct (AWQ 4-bit) | raw-vLLM (direct Service) | 1× L4 | 16384 | $0.5 / $1.5 per MTok | per-model TBD (re-derive on coder tier) | HumanEval 18/20 = 90% (≥70% gate) |
| `coder-fim` | Qwen2.5-Coder-1.5B (base) | raw-vLLM (direct Service) | 1× L4 | 8192 | $0.2 / $0.4 per MTok | per-model TBD | Validated: FIM `/v1/completions` 200 (direct + vkey) |
| `coder-agent` | Qwen2.5-Coder-14B-Instruct (AWQ 4-bit) | raw-vLLM (direct Service) | 1× L4 | 16384 | $0.5 / $1.5 per MTok | per-model TBD | Validated: 2-step autonomous tool loop via budgeted vkey |
| `embeddings` | BAAI/bge-base-en-v1.5 (TEI) | text-embeddings-inference (CPU) | none | 512 | $0.1 / n/a per MTok | n/a (embeddings) | Validated: registered + budget-binding (CPU proof path) |
| `claude-haiku` | claude-haiku-4-5 (Anthropic) | LiteLLM → agentgateway egress | none | provider | $1 / $5 per MTok (list price) | n/a (external) | External provider |

## Notes per model

**`qwen-local`**: the benchmark/baseline endpoint. Served raw on GPU and, identically, via a KServe
modelcar (`qwen-oci`, digest-pinned `oci://`) so the raw-vs-KServe comparison is engine-identical (same
vLLM `v0.23.0`). A CPU KServe variant (`qwen-cpu`, `max-model-len=4096`) exists for the
GPU-stocked-out proof path. The SLOs are baseline-specific and re-derived per model/GPU.

**`coder-chat` / `coder-fim` / `coder-agent`**: the coding tier.
Routed **direct to per-model Services** (single replica; GIE InferencePools are added when they go
multi-replica). FIM is the **base** model, not Instruct (instruct models mangle the FIM control tokens);
clients format the `<|fim_prefix|>…<|fim_suffix|>…<|fim_middle|>` prompt against `/v1/completions`. The
agent model is served with `--enable-auto-tool-choice` + the Hermes tool-call parser. AWQ 4-bit on the
7B/14B is what lets them fit a 24 GB L4 with a usable context. SLOs are recorded only for the 0.5B
baseline; per-model coder SLOs are a tracked follow-up once multi-replica serving lands.

**`embeddings`**: BAAI/bge-base-en-v1.5 on CPU (~140M, no GPU), for `@codebase` / RAG. bge over
nomic-embed-text because TEI's strict parser rejects nomic's `config.json` (duplicate
`max_position_embeddings`). Registered in LiteLLM so it sits behind the same gateway, keys, and budgets;
a per-token price is set because embeddings still consume compute and a price is required for budgets to
bind (the CPU budget-proof path when the GPU is stocked out).

**`claude-haiku`**: an external provider reached through the **unified egress**. LiteLLM points at the
in-cluster agentgateway (not `api.anthropic.com`), whose AnthropicBackend translates to `/v1/messages`
and normalizes the reply to OpenAI shape *with* a `usage` object, so LiteLLM still computes spend. The
provider key lives in agentgateway (ESO `anthropic-api-key`), not LiteLLM. Cost = Anthropic list price
for `claude-haiku-4-5`.

## How to read the columns

- **Backend**: raw-vLLM (hand-rolled Deployment+Service+PVC, the simple/benchmark path), KServe (the
  lifecycle/modelcar control plane), TEI (embeddings), or external via agentgateway egress
  ([serving layers compared](/architecture/serving-layers)).
- **GPU**: what one replica requests. "1× L4" means a whole GPU; the coder tier serves serially on one
  L4 because the models are memory-bound, not compute-bound.
- **Cost**: illustrative per-token prices from `model_list`; set so spend/budgets bind, not measured
  amortization. Replace with your GPU-hour amortization in a real deployment.
- **SLO target**: only `qwen-local` has measured SLOs (single model/GPU baseline); the rest are TBD by
  design until multi-replica serving triggers per-model derivation.
- **Eval status**: what has actually been proven, not what is authored.
