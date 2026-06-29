locals {
  # The module wants contiguous ids starting at 1; derive the node lists from simple counts so the
  # tfvars surface stays a count + type instead of hand-written object lists.
  control_plane_nodes = [
    for i in range(1, var.control_plane_count + 1) : {
      id   = i
      type = var.control_plane_server_type
    }
  ]

  worker_nodes = [
    for i in range(1, var.worker_count + 1) : {
      id   = i
      type = var.worker_server_type
    }
  ]
}

module "talos" {
  source  = "hcloud-talos/talos/hcloud"
  version = "3.4.11"

  hcloud_token = var.hcloud_token

  cluster_name  = var.cluster_name
  location_name = var.location_name

  talos_version      = var.talos_version
  kubernetes_version = var.kubernetes_version

  network_ipv4_cidr = var.network_ipv4_cidr

  control_plane_nodes = local.control_plane_nodes
  worker_nodes        = local.worker_nodes

  # Cilium enforcing native networking.k8s.io/v1 NetworkPolicy = parity with GKE Dataplane-V2 (ADR-0029
  # SR1); no CiliumNetworkPolicy CRD lock-in. The module deploys Cilium by default — pinned here for intent.
  deploy_cilium = true

  # hcloud CCM provides the cloud LoadBalancer (for the gateway Service) and node lifecycle. Argo CD adds
  # hcloud-csi for RWO PVCs on top. Off-GKE this is the cloud-integration layer the proof exercises.
  deploy_hcloud_ccm = true

  # Lock the Kube/Talos API firewall to the operator's current public IP. A throwaway proof cluster does
  # not need a world-open API; widen via the module's firewall_*_source vars for CI/remote access.
  firewall_use_current_ip = true
}
