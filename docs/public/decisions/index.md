---
title: "Design rationale"
---

Why the platform is built the way it is. These records capture the public tradeoffs behind the v1
platform shape: serving, routing, tenancy, security, delivery, and operations.

The full ADR history stays in the repository. This page keeps only the decisions that help operators
understand the platform they are installing.

## Platform and scheduling

| Record | Decision |
| --- | --- |
| [ADR-0001](/decisions/0001-gpu-operator-vs-managed) | Use the provider-managed GPU stack, not a self-managed GPU Operator |
| [ADR-0002](/decisions/0002-kueue-quota-admission) | Kueue for GPU quota and admission |
| [ADR-0014](/decisions/0014-autoscaling) | Autoscale on vLLM queue depth, not GPU utilization |
| [ADR-0025](/decisions/0025-cold-start) | Cold start as four independent, cloud-agnostic levers |

## Serving

| Record | Decision |
| --- | --- |
| [ADR-0003](/decisions/0003-inference-slos) | Inference SLOs and the metrics that back them |
| [ADR-0006](/decisions/0006-raw-vllm-vs-kserve) | Raw vLLM as default; KServe as the lifecycle alternative |
| [ADR-0016](/decisions/0016-model-delivery) | Digest-pinned OCI modelcar as the model-delivery default |
| [ADR-0032](/decisions/0032-guidellm-serving-benchmark) | GuideLLM as the standard serving benchmark |

## Routing and tenancy

| Record | Decision |
| --- | --- |
| [ADR-0005](/decisions/0005-inference-aware-routing) | Inference-aware routing with the Gateway API Inference Extension |
| [ADR-0013](/decisions/0013-gateway-layering) | LiteLLM layered above the inference gateway, not instead of it |
| [ADR-0033](/decisions/0033-mcp-gateway-profile) | Governed MCP gateway profile |

## Security, secrets, and identity

| Record | Decision |
| --- | --- |
| [ADR-0011](/decisions/0011-secrets-and-config-strategy) | Secrets and config strategy |
| [ADR-0026](/decisions/0026-auth-sso) | Authentication and SSO with Dex and oauth2-proxy |
| [ADR-0029](/decisions/0029-security-enforcement) | Force the budget path, gate GPU admission, fail closed |
| [ADR-0034](/decisions/0034-tenant-edge-guardrails) | Tenant-edge guardrails: PII masking and prompt-injection block |

## Observability

| Record | Decision |
| --- | --- |
| [ADR-0015](/decisions/0015-llm-observability) | Spend dashboard from Postgres now, deeper tracing deferred |

## Delivery and configuration

| Record | Decision |
| --- | --- |
| [ADR-0000](/decisions/0000-scope) | Scope: what this is, what it is not, and the bar |
| [ADR-0027](/decisions/0027-deployment-profiles) | Deployment profiles as additive layer roots |
| [ADR-0028](/decisions/0028-iac-cloud-substrate) | IaC owns the cloud substrate; Argo CD owns in-cluster lifecycle |
| [ADR-0031](/decisions/0031-config-driven-feature-selection) | Config-driven feature selection |
