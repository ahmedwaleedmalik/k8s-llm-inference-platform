variable "project_id" {
  description = "GCP project ID. Keep this aligned with environments/ai-dev/config.yaml."
  type        = string

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{4,28}[a-z0-9]$", var.project_id))
    error_message = "project_id must look like a GCP project ID."
  }
}

variable "cluster_name" {
  description = "GKE cluster name."
  type        = string
  default     = "ai-dev"
}

variable "region" {
  description = "GCP region for regional resources such as Artifact Registry."
  type        = string
  default     = "us-central1"
}

variable "location" {
  description = "GKE location. The lab default is a zonal cluster."
  type        = string
  default     = "us-central1-a"
}

variable "release_channel" {
  description = "GKE release channel."
  type        = string
  default     = "REGULAR"

  validation {
    condition     = contains(["RAPID", "REGULAR", "STABLE"], upper(var.release_channel))
    error_message = "release_channel must be RAPID, REGULAR, or STABLE."
  }
}

variable "platform_node_pool_name" {
  description = "Always-on CPU node pool for Argo CD, ESO, observability, and controllers."
  type        = string
  default     = "default-pool"
}

variable "platform_machine_type" {
  description = "CPU node shape for the always-on platform pool."
  type        = string
  default     = "e2-standard-4"
}

variable "platform_min_node_count" {
  description = "Always-on minimum for the platform pool (warm baseline for Argo/ESO/observability)."
  type        = number
  default     = 1
}

variable "platform_max_node_count" {
  description = "Autoscaling ceiling for the platform pool (headroom for serving/gateway/demos)."
  type        = number
  default     = 3
}

variable "node_service_account_id" {
  description = "Service account ID used by GKE nodes."
  type        = string
  default     = "gke-ai-dev-nodes"

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{4,28}[a-z0-9]$", var.node_service_account_id))
    error_message = "node_service_account_id must be 6-30 chars, lowercase letters/digits/hyphens."
  }
}

variable "external_secrets_service_account_id" {
  description = "Google service account ID bound to the external-secrets/external-secrets Kubernetes SA."
  type        = string
  default     = "external-secrets"
}

variable "gpu_node_pool_name" {
  description = "Scale-to-zero GPU node pool name."
  type        = string
  default     = "gpu-l4"
}

variable "gpu_machine_type" {
  description = "GPU node machine type."
  type        = string
  default     = "g2-standard-4"
}

variable "gpu_accelerator_type" {
  description = "GKE accelerator type."
  type        = string
  default     = "nvidia-l4"
}

variable "gpu_count" {
  description = "Accelerators per GPU node."
  type        = number
  default     = 1
}

variable "gpu_min_node_count" {
  description = "GPU pool autoscaling minimum. Keep 0 for lab $0 GPU idle."
  type        = number
  default     = 0
}

variable "gpu_max_node_count" {
  description = "GPU pool autoscaling maximum."
  type        = number
  default     = 1
}

variable "gpu_disk_size_gb" {
  description = "Boot disk size for GPU nodes. Modelcar images consume node image-cache disk."
  type        = number
  default     = 100
}

variable "modelcar_repository_id" {
  description = "Artifact Registry Docker repo for OCI modelcars."
  type        = string
  default     = "models"
}

variable "manage_workload_iam" {
  description = <<-EOT
    Create the custom node + ESO service accounts and their IAM bindings (project roles, the ESO
    Workload Identity binding). Default true = the published GKE reference. Set false for a
    minimal-footprint / restricted-IAM apply: nodes fall back to the default compute SA and no
    project/SA IAM policy is written, so an editor-only identity can apply this root. ESO must then
    use an in-cluster secret source (no GSM Workload Identity).
  EOT
  type        = bool
  default     = true
}

variable "create_modelcar_repo" {
  description = <<-EOT
    Create the Artifact Registry modelcar repo and the node reader binding. Default true. Set false
    when serving from public images + on-demand model pulls (no OCI modelcars), which also drops the
    artifactregistry API enablement and avoids AR IAM.
  EOT
  type        = bool
  default     = true
}
