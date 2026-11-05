# Names shared with gcp/bootstrap, which creates the service accounts: the
# Terraform account may act as them but not create them.

locals {
  api_service_account   = "spry-api@${var.project_id}.iam.gserviceaccount.com"
  build_service_account = "spry-build@${var.project_id}.iam.gserviceaccount.com"

  # Firebase Hosting's default site serves both; /api/** is rewritten to the API,
  # so the browser never makes a cross-origin call to it.
  site_origins = [
    "https://${var.project_id}.web.app",
    "https://${var.project_id}.firebaseapp.com",
  ]
}

# A fresh project has every API switched off.
resource "google_project_service" "apis" {
  for_each = toset([
    "artifactregistry.googleapis.com",
    "cloudbuild.googleapis.com",
    "run.googleapis.com",
    "secretmanager.googleapis.com",
    "sqladmin.googleapis.com",
  ])

  service = each.value
  # Turning an API off deletes what is still in it; destroy removes the
  # resources and leaves the switches.
  disable_on_destroy = false
}
