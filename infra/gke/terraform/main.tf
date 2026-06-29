locals {
  required_services = toset(concat(
    [
      "cloudbuild.googleapis.com",
      "compute.googleapis.com",
      "container.googleapis.com",
      "iamcredentials.googleapis.com",
    ],
    var.create_modelcar_repo ? ["artifactregistry.googleapis.com"] : [],
    var.manage_workload_iam ? ["secretmanager.googleapis.com"] : [],
  ))

  node_roles = toset([
    "roles/logging.logWriter",
    "roles/monitoring.metricWriter",
    "roles/monitoring.viewer",
    "roles/stackdriver.resourceMetadata.writer",
  ])

  # null => GKE node pools use the project default compute SA (no custom SA / IAM required).
  node_service_account = var.manage_workload_iam ? google_service_account.nodes[0].email : null
}

resource "google_project_service" "required" {
  for_each = local.required_services

  project            = var.project_id
  service            = each.key
  disable_on_destroy = false
}

resource "google_service_account" "nodes" {
  count = var.manage_workload_iam ? 1 : 0

  project      = var.project_id
  account_id   = var.node_service_account_id
  display_name = "GKE nodes for ${var.cluster_name}"

  depends_on = [google_project_service.required]
}

resource "google_project_iam_member" "node_roles" {
  for_each = var.manage_workload_iam ? local.node_roles : toset([])

  project = var.project_id
  role    = each.key
  member  = "serviceAccount:${google_service_account.nodes[0].email}"
}

resource "google_service_account" "external_secrets" {
  count = var.manage_workload_iam ? 1 : 0

  project      = var.project_id
  account_id   = var.external_secrets_service_account_id
  display_name = "External Secrets Operator"

  depends_on = [google_project_service.required]
}

resource "google_project_iam_member" "external_secrets_secret_accessor" {
  count = var.manage_workload_iam ? 1 : 0

  project = var.project_id
  role    = "roles/secretmanager.secretAccessor"
  member  = "serviceAccount:${google_service_account.external_secrets[0].email}"
}

resource "google_service_account_iam_member" "external_secrets_workload_identity" {
  count = var.manage_workload_iam ? 1 : 0

  service_account_id = google_service_account.external_secrets[0].name
  role               = "roles/iam.workloadIdentityUser"
  member             = "serviceAccount:${var.project_id}.svc.id.goog[external-secrets/external-secrets]"

  depends_on = [google_container_cluster.main]
}

resource "google_artifact_registry_repository" "modelcars" {
  count = var.create_modelcar_repo ? 1 : 0

  project       = var.project_id
  location      = var.region
  repository_id = var.modelcar_repository_id
  description   = "OCI modelcars for KServe"
  format        = "DOCKER"

  depends_on = [google_project_service.required]
}

resource "google_artifact_registry_repository_iam_member" "node_modelcar_reader" {
  count = var.create_modelcar_repo && var.manage_workload_iam ? 1 : 0

  project    = var.project_id
  location   = google_artifact_registry_repository.modelcars[0].location
  repository = google_artifact_registry_repository.modelcars[0].repository_id
  role       = "roles/artifactregistry.reader"
  member     = "serviceAccount:${google_service_account.nodes[0].email}"
}

# Master authorized networks (GCP-0061) is deliberately not enabled: a control-plane CIDR allowlist
# locks out a single-operator lab whose kubectl/`make` run from a roaming, dynamic IP, and a forker's
# IP is unknowable at apply time. Documented as a deferred control in reference/security.md.
#trivy:ignore:AVD-GCP-0061
resource "google_container_cluster" "main" {
  name     = var.cluster_name
  project  = var.project_id
  location = var.location

  remove_default_node_pool = true
  initial_node_count       = 1
  deletion_protection      = false
  networking_mode          = "VPC_NATIVE"

  # Dataplane-V2 (Cilium-backed) = the NetworkPolicy-enforcing CNI required for ADR-0029 SR1. It
  # enforces the native networking.k8s.io/v1 API (no CiliumNetworkPolicy CRD lock-in). Must be set at
  # cluster creation — toggling it on an existing cluster forces recreation (ADR-0028), so it lives
  # here, not as a day-2 change. Built-in policy enforcement supersedes the legacy network_policy addon.
  datapath_provider = "ADVANCED_DATAPATH"

  release_channel {
    channel = upper(var.release_channel)
  }

  workload_identity_config {
    workload_pool = "${var.project_id}.svc.id.goog"
  }

  ip_allocation_policy {}

  depends_on = [google_project_service.required]
}

resource "google_container_node_pool" "platform" {
  name     = var.platform_node_pool_name
  project  = var.project_id
  location = var.location
  cluster  = google_container_cluster.main.name

  initial_node_count = var.platform_min_node_count

  autoscaling {
    min_node_count = var.platform_min_node_count
    max_node_count = var.platform_max_node_count
  }

  management {
    auto_repair  = true
    auto_upgrade = true
  }

  node_config {
    machine_type    = var.platform_machine_type
    service_account = local.node_service_account
    oauth_scopes    = ["https://www.googleapis.com/auth/cloud-platform"]

    metadata = {
      disable-legacy-endpoints = "true"
    }

    workload_metadata_config {
      mode = "GKE_METADATA"
    }
  }
}

resource "google_container_node_pool" "gpu" {
  name     = var.gpu_node_pool_name
  project  = var.project_id
  location = var.location
  cluster  = google_container_cluster.main.name

  initial_node_count = var.gpu_min_node_count

  autoscaling {
    min_node_count = var.gpu_min_node_count
    max_node_count = var.gpu_max_node_count
  }

  management {
    auto_repair  = true
    auto_upgrade = true
  }

  node_config {
    machine_type    = var.gpu_machine_type
    disk_size_gb    = var.gpu_disk_size_gb
    image_type      = "COS_CONTAINERD"
    service_account = local.node_service_account
    oauth_scopes    = ["https://www.googleapis.com/auth/cloud-platform"]

    guest_accelerator {
      type  = var.gpu_accelerator_type
      count = var.gpu_count

      gpu_driver_installation_config {
        gpu_driver_version = "DEFAULT"
      }
    }

    taint {
      key    = "nvidia.com/gpu"
      value  = "present"
      effect = "NO_SCHEDULE"
    }

    metadata = {
      disable-legacy-endpoints = "true"
    }

    workload_metadata_config {
      mode = "GKE_METADATA"
    }
  }
}
