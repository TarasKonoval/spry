# What goes on the HCP Terraform workspace (environment variables) and into
# the Makefile. None of it is secret.

output "TFC_GCP_RUN_SERVICE_ACCOUNT_EMAIL" {
  value = google_service_account.terraform.email
}

output "TFC_GCP_WORKLOAD_PROVIDER_NAME" {
  value = google_iam_workload_identity_pool_provider.hcp.name
}

output "api_service_account_email" {
  value = google_service_account.api.email
}

output "build_service_account_email" {
  value = google_service_account.build.email
}

output "build_source_bucket" {
  value = google_storage_bucket.build_source.name
}

output "project_number" {
  value = data.google_project.this.number
}
