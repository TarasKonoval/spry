# The backend image, built by Cloud Build from backend/Dockerfile (make
# gcp-build). The newest two versions stay, under the 0.5 GB free tier.

resource "google_artifact_registry_repository" "spry" {
  repository_id = "spry"
  location      = var.region
  format        = "DOCKER"

  cleanup_policy_dry_run = false

  cleanup_policies {
    id     = "keep-newest-2"
    action = "KEEP"

    most_recent_versions {
      keep_count = 2
    }
  }

  cleanup_policies {
    id     = "delete-older"
    action = "DELETE"

    condition {
      tag_state  = "ANY"
      older_than = "86400s"
    }
  }

  depends_on = [google_project_service.apis]
}

resource "google_artifact_registry_repository_iam_member" "build_pushes" {
  location   = google_artifact_registry_repository.spry.location
  repository = google_artifact_registry_repository.spry.name
  role       = "roles/artifactregistry.writer"
  member     = "serviceAccount:${local.build_service_account}"
}
