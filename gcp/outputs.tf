# What the Makefile reads (make gcp-*). None of it is secret: the database URL
# stays in Secret Manager.

output "api_url" {
  value = google_cloud_run_v2_service.api.uri
}

output "api_service" {
  value = google_cloud_run_v2_service.api.name
}

output "migrate_job" {
  value = google_cloud_run_v2_job.migrate.name
}

output "image_repository" {
  description = "Where make gcp-build pushes the backend image"
  value       = "${google_artifact_registry_repository.spry.location}-docker.pkg.dev/${var.project_id}/${google_artifact_registry_repository.spry.repository_id}"
}

output "db_instance" {
  value = google_sql_database_instance.main.name
}

output "db_connection_name" {
  value = google_sql_database_instance.main.connection_name
}

output "site_url" {
  value = local.site_origins[0]
}
