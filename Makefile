CLUSTER ?= ai-dev
PROFILE ?= platform
TF_DIR ?= infra/gke/terraform
TOFU ?= $(shell if command -v tofu >/dev/null 2>&1; then command -v tofu; elif command -v terraform >/dev/null 2>&1; then command -v terraform; else echo tofu; fi)

# Cluster targeting: this repo only ever talks to its own kubeconfig, never your global
# ~/.kube/config / current-context, so a context switch or kubeconfig overwrite elsewhere can't
# silently redirect a deploy. Default ./kubeconfig (gitignored); override CLUSTER_KUBECONFIG to
# relocate it. Generate it once with:
#   gcloud container clusters get-credentials <name> --region <r> --project <p> --kubeconfig=$(CURDIR)/kubeconfig
CLUSTER_KUBECONFIG ?= $(CURDIR)/kubeconfig
export CLUSTER_KUBECONFIG
export KUBECONFIG := $(CLUSTER_KUBECONFIG)

.PHONY: help require-kube fork-init render-config resolve-groups resolve-profile resolve-secret-store resolve-gpu resolve-guardrails config-check tf-fmt tf-init tf-validate tf-plan tf-apply tf-destroy tf-credentials bootstrap argocd-repo root seed-secrets reset-dex-admin seed-experience credentials wait smoke verify doctor pause resume argocd-password argocd-ui vllm-up vllm-down vllm-smoke bench keda-demo-up keda-demo-down modelcar-build bench-guidellm gpu-smoke guardrails-smoke docs-serve docs-build

MODEL ?= Qwen/Qwen2.5-0.5B-Instruct
IMAGE ?= REGION-docker.pkg.dev/PROJECT/REPO/qwen2.5-0.5b:v1

help: ## Show this help
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | awk 'BEGIN{FS=":.*?## "}{printf "  %-18s %s\n", $$1, $$2}'

require-kube: ## Validate + print the dedicated cluster target (./kubeconfig); the gate every cluster command runs first
	@./scripts/kube-target.sh

fork-init: ## Propagate environments/$(CLUSTER)/config.yaml (repoURL + GCP project + domain), then resolve all *.generated.yaml
	ENV=$(CLUSTER) ./scripts/fork-init.sh
	$(MAKE) resolve-groups CLUSTER=$(CLUSTER)

render-config: resolve-groups ## Render config.yaml into committed GitOps artifacts (preferred alias)

resolve-groups: resolve-profile resolve-secret-store resolve-gpu resolve-guardrails ## Resolve config.yaml features into clusters/$(CLUSTER)/groups.generated.yaml (also runs resolve-profile + resolve-secret-store + resolve-gpu + resolve-guardrails)
	ENV=$(CLUSTER) ./scripts/resolve-groups.sh

resolve-profile: ## Resolve config.yaml profile (cost|dev|prod) into the litellm + CNPG HA overlays
	ENV=$(CLUSTER) ./scripts/resolve-profile.sh

resolve-secret-store: ## Resolve config.yaml secret_store_auth (workload-identity|sa-key) into the ESO ClusterSecretStore
	ENV=$(CLUSTER) ./scripts/resolve-secret-store.sh

resolve-gpu: ## Resolve config.yaml gpu_stack (gke-managed|operator|none) into the DCGM scrape target (platform/dcgm-metrics)
	ENV=$(CLUSTER) ./scripts/resolve-gpu.sh

resolve-guardrails: ## Resolve config.yaml features.guardrails into the LiteLLM guardrails values overlay (ADR-0034)
	ENV=$(CLUSTER) ./scripts/resolve-guardrails.sh

config-check: ## Validate config.yaml propagation and tfvars drift
	ENV=$(CLUSTER) ./scripts/config-check.sh

tf-fmt: ## Check OpenTofu/Terraform formatting
	ENV=$(CLUSTER) TF_DIR=$(TF_DIR) TOFU=$(TOFU) ./scripts/tofu.sh fmt -check -recursive

tf-init: ## Initialize the GKE OpenTofu root
	ENV=$(CLUSTER) TF_DIR=$(TF_DIR) TOFU=$(TOFU) ./scripts/tofu.sh init

tf-validate: ## Validate the GKE OpenTofu root (run after tf-init)
	ENV=$(CLUSTER) TF_DIR=$(TF_DIR) TOFU=$(TOFU) ./scripts/tofu.sh validate

tf-plan: ## Plan the GKE cloud substrate
	ENV=$(CLUSTER) TF_DIR=$(TF_DIR) TOFU=$(TOFU) ./scripts/tofu.sh plan

tf-apply: ## Apply the GKE cloud substrate (paid cloud resources; set AUTO_APPROVE=1 for non-interactive/CI)
	ENV=$(CLUSTER) TF_DIR=$(TF_DIR) TOFU=$(TOFU) ./scripts/tofu.sh apply $(if $(filter 1 yes,$(AUTO_APPROVE)),-auto-approve)

tf-destroy: ## Destroy the GKE cloud substrate (read teardown.md first)
	ENV=$(CLUSTER) TF_DIR=$(TF_DIR) TOFU=$(TOFU) ./scripts/tofu.sh destroy

tf-credentials: ## Print the gcloud get-credentials command from Terraform output
	@ENV=$(CLUSTER) TF_DIR=$(TF_DIR) TOFU=$(TOFU) ./scripts/tofu.sh output -raw get_credentials_command
	@echo

bootstrap: ## Install Argo CD on the repo's dedicated cluster (./kubeconfig; pinned chart)
	./bootstrap/install.sh

argocd-repo: require-kube ## Create/update the Argo CD repo cred from env (ARGOCD_REPO_PAT[, ARGOCD_REPO_USERNAME]) — private repo only
	@test -n "$(ARGOCD_REPO_PAT)" || { echo "set ARGOCD_REPO_PAT (fine-grained PAT, Contents: Read-only)"; exit 1; }
	@kubectl -n argocd create secret generic repo-priv \
	  --from-literal=type=git \
	  --from-literal=url=https://github.com/ahmedwaleedmalik/k8s-llm-inference-platform.git \
	  --from-literal=username=$(or $(ARGOCD_REPO_USERNAME),x-access-token) \
	  --from-literal=password=$(ARGOCD_REPO_PAT) \
	  --dry-run=client -o yaml | kubectl apply -f -
	@kubectl -n argocd label secret repo-priv argocd.argoproj.io/secret-type=repository --overwrite

root: require-kube ## Apply the platform AppProject + per-layer ApplicationSets for PROFILE (platform|serving|llm-gateway|full; default platform). Run argocd-repo first while the repo is private.
	@case "$(PROFILE)" in \
	  platform)    layers="platform" ;; \
	  serving)     layers="platform serving" ;; \
	  llm-gateway) layers="platform serving routing llm-gateway" ;; \
	  full)        layers="platform serving routing llm-gateway experience demos" ;; \
	  *) echo "unknown PROFILE=$(PROFILE) — use platform|serving|llm-gateway|full"; exit 1 ;; \
	esac; \
	test -s clusters/$(CLUSTER)/groups.generated.yaml || { echo "missing/empty groups.generated.yaml — run 'make resolve-groups'"; exit 1; }; \
	kubectl apply -f clusters/$(CLUSTER)/projects/platform.yaml; \
	for l in $$layers; do echo "==> appset: $$l"; kubectl apply -f clusters/$(CLUSTER)/appsets/$$l.yaml; done

# seed-secrets writes to the secret backend (gcloud / backend CLI), not the cluster, so it deliberately
# skips the require-kube gate — this lets it run before the cluster exists (Vault-first / seed-then-provision).
seed-secrets: ## Seed the internal random secrets (LiteLLM/vLLM/Dex/oauth2-proxy/DB) into the backend, idempotent; prints the real external ones you must provide
	ENV=$(CLUSTER) ./scripts/seed-secrets.sh

reset-dex-admin: require-kube ## Rotate lost Dex static-admin password, persist it in GSM, force ESO refresh/restart Dex
	ENV=$(CLUSTER) ./scripts/reset-dex-admin.sh

seed-experience: require-kube ## (optional) Manually re-mint Open WebUI's secret; the litellm-keys Job mints both apps' keys automatically
	./scripts/seed-experience-secrets.sh

credentials: require-kube ## Collate operator credentials into the gitignored secrets/credentials.local.md (SSO is the real path)
	ENV=$(CLUSTER) ./scripts/credentials.sh

wait: require-kube ## Wait for auto-sync apps in PROFILE to become Synced+Healthy
	ENV=$(CLUSTER) PROFILE=$(PROFILE) ./scripts/wait-profile.sh

smoke: require-kube ## Run profile smoke checks (serving profile runs vLLM smoke)
	ENV=$(CLUSTER) PROFILE=$(PROFILE) ./scripts/smoke-profile.sh

verify: require-kube ## End-to-end platform check (GitOps + economics + budget-429 + serving + edge/SSO), plain pass/fail
	ENV=$(CLUSTER) ./scripts/verify.sh

doctor: require-kube ## Validate local config + live cluster prerequisites for PROFILE
	ENV=$(CLUSTER) ./scripts/doctor.sh $(PROFILE)

pause: require-kube ## Pause to $0: release Gateway LBs, tofu destroy substrate, audit orphans (DESTRUCTIVE; GSM secrets survive)
	ENV=$(CLUSTER) ./scripts/pause.sh

resume: ## Resume from a paused (destroyed) cluster: tofu apply + bootstrap + platform base
	ENV=$(CLUSTER) ./scripts/resume.sh

argocd-password: require-kube ## Print the initial Argo CD admin password, if built-in admin is enabled
	@if kubectl -n argocd get secret argocd-initial-admin-secret >/dev/null 2>&1; then \
	  kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | openssl base64 -d -A; echo; \
	else \
	  echo "built-in admin disabled; use Dex SSO after identity sync"; \
	fi

argocd-ui: require-kube ## Port-forward the Argo CD UI to localhost:8080
	kubectl -n argocd port-forward svc/argo-cd-argocd-server 8080:80

vllm-up: require-kube ## Scale raw-vllm to 1 (brings up an L4 node — costs while running)
	kubectl -n serving scale deploy/raw-vllm --replicas=1
	kubectl -n serving rollout status deploy/raw-vllm --timeout=15m

vllm-down: require-kube ## Scale raw-vllm to 0 (releases the L4 node — $0 idle)
	kubectl -n serving scale deploy/raw-vllm --replicas=0

vllm-smoke: require-kube ## Send an authenticated OpenAI chat request to raw-vllm (run after vllm-up)
	./scripts/smoke-chat.sh

guardrails-smoke: require-kube ## Prove the LiteLLM guardrails: PII masked + prompt-injection blocked (needs features.guardrails: true synced)
	./scripts/smoke-guardrails.sh

keda-demo-up: require-kube ## Un-pause the raw-vllm KEDA ScaledObject (autoscaling on — load-test only; runbook keda-autoscaling.md)
	kubectl -n serving annotate scaledobject raw-vllm autoscaling.keda.sh/paused=false --overwrite

keda-demo-down: require-kube ## Re-pause the raw-vllm KEDA ScaledObject (back to manual make vllm-up/down)
	kubectl -n serving annotate scaledobject raw-vllm autoscaling.keda.sh/paused=true --overwrite

modelcar-build: ## Build+push the OCI modelcar and print the @sha256 digest to pin (MODEL=, IMAGE=; needs docker)
	./scripts/build-modelcar.sh $(MODEL) $(IMAGE)

bench: require-kube ## Run the vLLM concurrency-sweep smoke benchmark Job (run after vllm-up)
	kubectl -n serving delete job vllm-bench --ignore-not-found
	kubectl -n serving apply -f benchmarks/job.yaml
	kubectl -n serving wait --for=condition=complete --timeout=20m job/vllm-bench
	kubectl -n serving logs job/vllm-bench

bench-guidellm: require-kube ## Run the GuideLLM SLO-frontier sweep Job (standard serving benchmark, ADR-0032; after vllm-up)
	kubectl -n serving delete job guidellm-bench --ignore-not-found
	kubectl -n serving apply -f benchmarks/guidellm-job.yaml
	kubectl -n serving wait --for=condition=complete --timeout=20m job/guidellm-bench
	kubectl -n serving logs job/guidellm-bench

gpu-smoke: require-kube ## Run the nvidia-smi GPU smoke Job (verifies the GPU stack; triggers a GPU node, scales back to 0)
	kubectl -n default delete job gpu-smoke --ignore-not-found
	kubectl -n default apply -f workloads/gpu-smoke/job.yaml
	kubectl -n default wait --for=condition=complete --timeout=20m job/gpu-smoke
	kubectl -n default logs job/gpu-smoke
	kubectl -n default delete job gpu-smoke --ignore-not-found

docs-serve: ## Serve the docs site locally with live reload (Mintlify, http://localhost:3000)
	cd docs/public && mint dev

docs-build: ## Validate the docs site (broken-link check, same as CI)
	cd docs/public && mint broken-links
