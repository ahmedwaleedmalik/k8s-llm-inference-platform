#!/usr/bin/env bash
set -euo pipefail

cd "$(git rev-parse --show-toplevel)"

PROFILE="${1:-${PROFILE:-platform}}"
ENV="${ENV:-ai-dev}"
PROJECT="$(awk '$1=="projectID:" {print $2; exit}' "environments/${ENV}/config.yaml")"
CLUSTER_NAME="$(awk '$1=="name:" {print $2; exit}' "environments/${ENV}/config.yaml")"
LOCATION="$(awk '$1=="location:" {print $2; exit}' "environments/${ENV}/config.yaml")"
SECRET_BACKEND="$(awk '$1=="secret_backend:" {print $2; exit}' "environments/${ENV}/config.yaml")"
SECRET_BACKEND="${SECRET_BACKEND:-gcpsm}"
GPU_STACK="$(awk '$1=="gpu_stack:" {print $2; exit}' "environments/${ENV}/config.yaml")"
GPU_STACK="${GPU_STACK:-gke-managed}"
ECON_PROFILE="$(awk '$1=="profile:" {print $2; exit}' "environments/${ENV}/config.yaml")"
GPU_POOL="gpu-l4"
if [ -f infra/gke/terraform/terraform.tfvars ]; then
  parsed_pool="$(awk -F= '/^gpu_node_pool_name[ \t]*=/{gsub(/[ \t"]/, "", $2); print $2; exit}' infra/gke/terraform/terraform.tfvars)"
  [ -z "$parsed_pool" ] || GPU_POOL="$parsed_pool"
fi

case "$PROFILE" in
  platform) layers="platform" ;;
  serving) layers="platform serving" ;;
  llm-gateway) layers="platform serving routing llm-gateway" ;;
  full) layers="platform serving routing llm-gateway experience demos" ;;
  *) echo "unknown PROFILE=$PROFILE (use platform|serving|llm-gateway|full)" >&2; exit 1 ;;
esac

fail=0

need_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "FAIL missing command: $1"
    fail=1
  else
    echo "OK   command: $1"
  fi
}

has_layer() {
  case " $layers " in
    *" $1 "*) return 0 ;;
    *) return 1 ;;
  esac
}

need_cmd kubectl
need_cmd jq
# gcloud is only the source-of-truth check tool for the gcpsm secret backend; other backends don't need it.
if [ "$SECRET_BACKEND" = gcpsm ]; then need_cmd gcloud; fi

./scripts/config-check.sh || fail=1

if [ -s "clusters/${ENV}/groups.generated.yaml" ]; then
  echo "OK   groups.generated.yaml present"
else
  echo "FAIL groups.generated.yaml missing/empty — run 'make resolve-groups'"
  fail=1
fi

kube_ctx="$(kubectl config current-context 2>/dev/null || true)"
if kubectl --request-timeout=5s get --raw='/readyz' >/dev/null 2>&1; then
  echo "OK   kubectl reaches cluster (context: ${kube_ctx:-none})"
else
  echo "FAIL kubectl cannot reach cluster (context: ${kube_ctx:-none}); generate the dedicated ./kubeconfig (gcloud ... get-credentials --kubeconfig=\$PWD/kubeconfig) or set CLUSTER_KUBECONFIG"
  exit 1
fi

# Substrate detection from node providerID (gce:// on GKE, hcloud:// on Hetzner, etc.). Used to gate
# the GKE-only node-pool check; everything else is substrate-agnostic.
provider_id="$(kubectl get nodes -o jsonpath='{.items[0].spec.providerID}' 2>/dev/null || true)"
case "$provider_id" in gce://*) IS_GKE=1 ;; *) IS_GKE=0 ;; esac

for crd in applications.argoproj.io externalsecrets.external-secrets.io clustersecretstores.external-secrets.io; do
  if kubectl get crd "$crd" >/dev/null 2>&1; then
    echo "OK   CRD: $crd"
  else
    echo "FAIL missing CRD: $crd"
    fail=1
  fi
done

# Storage contract: every PVC omits storageClassName and inherits the cluster default,
# so the substrate must mark one StorageClass default — else PVCs (model caches, experience data,
# CNPG) stay Pending.
default_sc="$(kubectl get sc -o jsonpath='{range .items[?(@.metadata.annotations.storageclass\.kubernetes\.io/is-default-class=="true")]}{.metadata.name}{" "}{end}' 2>/dev/null)"
if [ -n "$default_sc" ]; then
  echo "OK   default StorageClass: $default_sc"
else
  echo "FAIL no default StorageClass — PVCs (model caches, experience data, CNPG) will stay Pending."
  echo "     set one: kubectl annotate sc <name> storageclass.kubernetes.io/is-default-class=true"
  fail=1
fi

# LoadBalancer contract: the public-edge gateways are Service type=LoadBalancer with NO cloud-specific
# annotations (kept substrate-agnostic), so the substrate's load-balancer integration (cloud CCM /
# controller) must assign an external IP/hostname — else the gateway is unreachable. Agnostic: any
# LB Service stuck without an external address fails here, whatever the cloud. (Hetzner: the hcloud
# CCM needs a default LB location/zone — HCLOUD_LOAD_BALANCERS_NETWORK_ZONE, see infra/hetzner/k3s.)
lb_svcs="$(kubectl get svc -A -o jsonpath='{range .items[?(@.spec.type=="LoadBalancer")]}{.metadata.namespace}/{.metadata.name}{"\t"}{.status.loadBalancer.ingress[0].ip}{.status.loadBalancer.ingress[0].hostname}{"\n"}{end}' 2>/dev/null)"
if [ -z "$lb_svcs" ]; then
  echo "SKIP no LoadBalancer Services present (public-edge not synced) — LB provisioning not assessed"
else
  pending="$(printf '%s\n' "$lb_svcs" | awk -F'\t' 'NF&&($2==""){print $1}')"
  if [ -n "$pending" ]; then
    echo "FAIL LoadBalancer Service(s) have no external address — the substrate LB integration is not provisioning:"
    printf '%s\n' "$pending" | sed 's/^/       /'
    echo "     check your cloud controller manager / LB controller. Hetzner: set a default LB zone on the"
    echo "     hcloud CCM (HCLOUD_LOAD_BALANCERS_NETWORK_ZONE) — see infra/hetzner/k3s/README.md."
    fail=1
  else
    echo "OK   LoadBalancer provisioning: all $(printf '%s\n' "$lb_svcs" | grep -c .) Service(s) have an external address"
  fi
fi

for layer in $layers; do
  appset="layer-${layer}"
  if kubectl -n argocd get applicationset "$appset" >/dev/null 2>&1; then
    echo "OK   Argo ApplicationSet exists: $appset"
  else
    echo "FAIL missing Argo ApplicationSet: $appset"
    fail=1
  fi
done

check_gsm_secret() {
  local name="$1" required="$2"
  # Source-of-truth check, gcpsm only. Other backends own their own store; ESO surfaces sync errors,
  # and the materialized k8s Secret is verified by check_k8s_secret regardless of backend.
  if [ "$SECRET_BACKEND" != gcpsm ]; then
    echo "SKIP GSM source check ($name): secret_backend=$SECRET_BACKEND"
    return 0
  fi
  if gcloud secrets describe "$name" --project "$PROJECT" >/dev/null 2>&1; then
    echo "OK   GSM secret: $name"
  elif [ "$required" = "true" ]; then
    echo "FAIL missing required GSM secret: $name"
    fail=1
  else
    echo "WARN missing optional GSM secret: $name"
  fi
}

check_k8s_secret() {
  local ns="$1" name="$2" required="$3"
  if kubectl -n "$ns" get secret "$name" >/dev/null 2>&1; then
    echo "OK   k8s secret: $ns/$name"
  elif [ "$required" = "true" ]; then
    echo "FAIL missing required k8s secret: $ns/$name"
    fail=1
  else
    echo "WARN missing optional k8s secret: $ns/$name"
  fi
}

if has_layer serving; then
  check_gsm_secret vllm-api-key true
  check_k8s_secret serving vllm-api-key true
  check_gsm_secret hf-token false
fi

if has_layer llm-gateway; then
  check_gsm_secret litellm-master-key true
  check_gsm_secret litellm-salt-key true
  check_gsm_secret litellm-db-password true
  check_gsm_secret litellm-grafana-ro-password true
  check_k8s_secret litellm litellm-secrets true
  check_k8s_secret litellm litellm-pg-app true
  check_k8s_secret litellm litellm-grafana-ro true
  check_k8s_secret monitoring grafana-datasource-litellm true

  # prod CNPG backups use method: volumeSnapshot, which needs the CSI external-snapshotter (CRDs) and a
  # default VolumeSnapshotClass (CNPG omits className → inherits the default). cost|dev: no backups.
  if [ "$ECON_PROFILE" = prod ]; then
    if kubectl get crd volumesnapshotclasses.snapshot.storage.k8s.io >/dev/null 2>&1; then
      default_vsc="$(kubectl get volumesnapshotclass -o jsonpath='{range .items[?(@.metadata.annotations.snapshot\.storage\.kubernetes\.io/is-default-class=="true")]}{.metadata.name}{" "}{end}' 2>/dev/null)"
      if [ -n "$default_vsc" ]; then
        echo "OK   default VolumeSnapshotClass: $default_vsc"
      else
        echo "FAIL prod: no default VolumeSnapshotClass — CNPG scheduled backups will fail."
        echo "     annotate one: kubectl annotate volumesnapshotclass <name> snapshot.storage.kubernetes.io/is-default-class=true"
        fail=1
      fi
    else
      echo "FAIL prod: VolumeSnapshot CRDs absent — install the CSI external-snapshotter, else CNPG backups fail."
      fail=1
    fi
  fi
fi

# GPU stack contract (ADR-0001): gpu_stack selects who provides the driver/device-plugin/DCGM.
# operator must NOT run on GKE (GKE's containerd rejects the operator's nvidia runtime — ADR-0001);
# gke-managed off-GKE means no GPU stack at all. Warn on the obvious mismatches.
case "$GPU_STACK" in
  gke-managed)
    [ "$IS_GKE" = 1 ] && echo "OK   gpu_stack=gke-managed on GKE" \
      || echo "WARN gpu_stack=gke-managed but substrate is not GKE — no GPU stack will be installed; set gpu_stack=operator for self-managed GPU"
    ;;
  operator)
    [ "$IS_GKE" = 0 ] && echo "OK   gpu_stack=operator on non-GKE substrate" \
      || echo "WARN gpu_stack=operator on GKE — the NVIDIA GPU Operator's nvidia runtime fails on GKE's containerd (ADR-0001); use gpu_stack=gke-managed"
    if kubectl get ns gpu-operator >/dev/null 2>&1; then
      echo "OK   gpu-operator namespace present"
    else
      echo "WARN gpu-operator namespace absent — sync the platform layer (gpu-operator group) so the operator installs the GPU stack"
    fi
    ;;
  none) echo "OK   gpu_stack=none (no GPU stack / no DCGM metrics)" ;;
  *) echo "FAIL gpu_stack=$GPU_STACK — use gke-managed|operator|none"; fail=1 ;;
esac

if has_layer serving; then
  if [ "$IS_GKE" = 1 ] && command -v gcloud >/dev/null 2>&1; then
    if gcloud container node-pools describe "$GPU_POOL" --cluster "$CLUSTER_NAME" --location "$LOCATION" --project "$PROJECT" >/dev/null 2>&1; then
      echo "OK   GPU node pool exists: $GPU_POOL"
    else
      echo "WARN GPU node pool $GPU_POOL not found; serving profile can sync, but GPU smoke will not run"
    fi
  else
    gpu_nodes="$(kubectl get nodes -o jsonpath='{range .items[*]}{.status.allocatable.nvidia\.com/gpu}{"\n"}{end}' 2>/dev/null | grep -c '^[1-9]' || true)"
    if [ "${gpu_nodes:-0}" -gt 0 ]; then
      echo "OK   GPU nodes advertising nvidia.com/gpu: $gpu_nodes"
    else
      echo "WARN no node currently advertises nvidia.com/gpu (scale-to-zero, or GPU stack not installed); GPU smoke will not run"
    fi
  fi
fi

exit "$fail"
