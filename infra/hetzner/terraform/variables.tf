variable "hcloud_token" {
  description = "Hetzner Cloud API token (Read & Write). The ONLY credential needed to stand up the cluster."
  type        = string
  sensitive   = true
}

variable "cluster_name" {
  description = "Talos/Kubernetes cluster name. Kept separate from the GKE 'ai-dev' name so both can coexist."
  type        = string
  default     = "ai-dev-hetzner"
}

variable "location_name" {
  description = "Hetzner Cloud location. Possible values: fsn1, nbg1, hel1 (EU), ash, hil (US), sin (APAC)."
  type        = string
  default     = "fsn1"

  validation {
    condition     = contains(["fsn1", "nbg1", "hel1", "ash", "hil", "sin"], var.location_name)
    error_message = "location_name must be one of: fsn1, nbg1, hel1, ash, hil, sin."
  }
}

variable "talos_version" {
  description = "Talos Linux version. Must be compatible with kubernetes_version per the Talos support matrix."
  type        = string
  default     = "v1.12.2"
}

variable "kubernetes_version" {
  description = "Kubernetes version. Keep within one minor of the GKE lab to keep the catalog/appsets portable."
  type        = string
  default     = "1.32.0"
}

# CPU-only serving for the portability proof: no GPU type exists in the hcloud API, so the
# cluster runs vLLM on CPU like the GKE GPU-stockout path. Control plane is a small box (tainted,
# non-scheduled by default); workers carry the platform (Argo CD, ESO, kube-prometheus-stack, KServe,
# Kueue, KEDA) plus CPU serving — hence the larger shape and RAM headroom.
variable "control_plane_count" {
  description = "Number of control plane nodes. Must be odd (1, 3, 5). 1 is fine for a throwaway proof."
  type        = number
  default     = 1

  validation {
    condition     = contains([1, 3, 5], var.control_plane_count)
    error_message = "control_plane_count must be 1, 3, or 5 (odd, per the Talos etcd quorum requirement)."
  }
}

variable "control_plane_server_type" {
  description = "Hetzner server type for control plane nodes (x86: cx*/cpx*/ccx*, ARM: cax*)."
  type        = string
  default     = "cx22"
}

variable "worker_count" {
  description = "Number of worker nodes sized to run the platform plus CPU serving."
  type        = number
  default     = 3

  validation {
    condition     = var.worker_count >= 1 && var.worker_count <= 99
    error_message = "worker_count must be between 1 and 99."
  }
}

variable "worker_server_type" {
  description = "Hetzner server type for worker nodes. cx42 (8 vCPU / 16 GB) gives CPU-serving headroom."
  type        = string
  default     = "cx42"
}

variable "network_ipv4_cidr" {
  description = "Private network CIDR for the cluster. Subnets for nodes/pods/services are carved from it."
  type        = string
  default     = "10.0.0.0/16"
}
