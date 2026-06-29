# clusters/ai-dev/catalog — capability-group catalog

Verbatim Argo CD `Application` manifests for the `ai-dev` cluster, grouped into **capability
groups** (ADR-0031). Each subdir is one group; a group is enabled/disabled via `config.yaml`
`features:` (resolved by `make resolve-groups` into `../groups.generated.yaml`). The per-layer
ApplicationSets in [`../appsets/`](../appsets) read that file and create one app-of-apps per enabled
group, recursing the group dir.

Two axes decide what runs: *staging* is which layers you apply (`make root PROFILE=…`), and
*selection* is which groups are enabled (`config.yaml features:`). A third, *bring-up*, is each app's
own `manual-sync` policy.

Groups (`-core` is always on):

| Layer | Groups |
|---|---|
| platform | `platform-core`, `autoscaling`, `identity`, `dns`, `security`, `opencost`, `gpu-operator` |
| serving | `serving-core`, `kserve`, `embeddings`, `coding-assistant`, `llm-d` |
| routing | `routing-core`, `public-edge`, `mcp-gateway`, `egress` |
| llm-gateway | `llm-gateway-core`, `guardrails` |
| experience | `experience`, `n8n` |
| demos | `demos` |

These dirs hold ONLY plain `kind: Application` YAML, never a `Chart.yaml` or `kustomization.yaml`
(a `directory.recurse` source renders plain manifests only). Each child carries
`resources-finalizer.argocd.argoproj.io` so disabling a group cascades a clean delete. See ADR-0031.
