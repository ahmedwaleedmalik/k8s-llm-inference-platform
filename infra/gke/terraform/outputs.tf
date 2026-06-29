output "cluster_name" {
  value = google_container_cluster.main.name
}

output "cluster_location" {
  value = google_container_cluster.main.location
}

output "get_credentials_command" {
  value = "gcloud container clusters get-credentials ${google_container_cluster.main.name} --location ${google_container_cluster.main.location} --project ${var.project_id}"
}

output "external_secrets_service_account" {
  value = var.manage_workload_iam ? google_service_account.external_secrets[0].email : "(disabled: ESO uses an in-cluster secret source)"
}

output "node_service_account" {
  value = var.manage_workload_iam ? google_service_account.nodes[0].email : "(default compute service account)"
}

output "modelcar_image_prefix" {
  value = var.create_modelcar_repo ? "${var.region}-docker.pkg.dev/${var.project_id}/${google_artifact_registry_repository.modelcars[0].repository_id}" : "(disabled: no modelcar repo)"
}
