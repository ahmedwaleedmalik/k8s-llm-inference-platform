---
title: "Guardrails"
---

Operating the optional `guardrails` capability group. It adds two tenant-edge checks to LiteLLM:
PII masking through self-hosted Presidio, and prompt-injection blocking through LiteLLM's built-in
content filter. The decision record is [ADR-0034](/decisions/0034-tenant-edge-guardrails).

## Model

- **`presidio-pii-mask`**: runs in LiteLLM `pre_call` mode. Presidio analyzer and anonymizer run in
  the `guardrails` namespace and mask email, phone, credit card, US SSN, IBAN, and person entities
  before the request leaves LiteLLM.
- **`prompt-injection-block`**: runs in LiteLLM `pre_call` mode. Matching prompts return HTTP 400
  before any model is called, so this check does not need a GPU.
- **Resolver wiring**: `scripts/resolve-guardrails.sh` writes
  `clusters/<env>/litellm-guardrails.generated.yaml`. When the feature is off, that file is an empty
  no-op overlay. When it is on, LiteLLM receives the `proxy_config.guardrails` block.

## 1. Enable

```bash
# environments/<env>/config.yaml
features:
  guardrails: true

make resolve-groups
git add -A && git commit -m "enable guardrails" && git push
```

Apply at least the `llm-gateway` layer:

```bash
make root PROFILE=llm-gateway
make wait PROFILE=llm-gateway
```

The `guardrails` catalog group deploys Presidio. The `llm-gateway-core` LiteLLM app consumes the
generated overlay.

## 2. Verify

Run the smoke test:

```bash
make guardrails-smoke
```

Expected result:

- Injection prompt returns HTTP 400.
- Presidio detects PII entities.
- The PII call through LiteLLM returns HTTP 200 when the `embeddings` model is Ready.

This path was live-proven on 2026-06-25 during the GKE acceptance run: injection returned HTTP 400,
Presidio masked EMAIL, PHONE, and URL, and the PII call completed with HTTP 200.

## 3. Tune

The default entity list and injection categories live in `scripts/resolve-guardrails.sh`. Edit the
resolver, then regenerate:

```bash
make resolve-groups
```

Commit the resolver change and the regenerated `clusters/<env>/litellm-guardrails.generated.yaml`
together. Do not hand-edit the generated file.

## 4. Troubleshoot

Check that the feature selected both pieces:

```bash
grep guardrails clusters/ai-dev/groups.generated.yaml
sed -n '1,120p' clusters/ai-dev/litellm-guardrails.generated.yaml
```

Check Presidio health:

```bash
kubectl -n guardrails get pods,svc
kubectl -n guardrails port-forward svc/presidio-analyzer 3000:3000
curl -fsS http://localhost:3000/health
```

If Presidio is slow to become Ready, wait for the analyzer to load its spaCy model. Memory is the
binding resource: the analyzer requests 1Gi and limits at 2Gi. If it OOMs, increase the
memory limit in `platform/guardrails/presidio-analyzer.yaml`.

If `make guardrails-smoke` says the LiteLLM master key is missing, seed or sync the LiteLLM secrets
first:

```bash
make seed-secrets
make root PROFILE=llm-gateway
```

If the PII completion check is not HTTP 200 but the injection and analyzer checks pass, bring the
CPU embeddings path up first. The script treats that completion leg as informational because the
guardrail itself is proven by the analyzer response and the LiteLLM HTTP 400 block.

## 5. Disable

Set `features.guardrails: false`, run `make resolve-groups`, commit, and push. Argo prunes the
Presidio app group and LiteLLM receives the no-op guardrails overlay.
