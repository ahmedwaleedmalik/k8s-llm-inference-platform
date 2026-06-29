output "cluster_name" {
  value = var.cluster_name
}

output "kubeconfig" {
  description = "Kubeconfig for the cluster. Write to a file before running Argo CD bootstrap."
  value       = module.talos.kubeconfig
  sensitive   = true
}

output "talosconfig" {
  description = "Talos client config for talosctl (node/OS lifecycle)."
  value       = module.talos.talosconfig
  sensitive   = true
}

output "control_plane_public_ips" {
  description = "Public IPv4 of the control plane nodes (Kube/Talos API endpoints)."
  value       = module.talos.public_ipv4_list
}

# Mirrors the GKE root's get_credentials_command: a copy-paste recipe to land a working kubeconfig.
output "get_credentials_command" {
  value = "cd infra/hetzner/terraform && tofu output -raw kubeconfig > ../../../kubeconfig.hetzner && export KUBECONFIG=$PWD/../../../kubeconfig.hetzner"
}
