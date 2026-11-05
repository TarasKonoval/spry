# What gcp/ needs before HCP Terraform can run it, applied once from a laptop
# with your own application default credentials (`make gcp-bootstrap-plan`,
# then `make gcp-bootstrap-apply`). Its state is local and gitignored; nothing
# in it is secret, and no service account key is ever created.
#
# The Terraform service account gets only the LAB9 Part 0 roles, so anything
# that needs more stays here: the other service accounts, their project-level
# roles, the workload identity pool, and adding Firebase to the project.

terraform {
  required_version = ">= 1.10"

  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 7.0"
    }
    google-beta = {
      source  = "hashicorp/google-beta"
      version = "~> 7.0"
    }
  }
}

provider "google" {
  project = var.project_id
  region  = var.region
}

# Firebase's APIs bill a quota project, which user credentials do not carry.
provider "google-beta" {
  project               = var.project_id
  region                = var.region
  user_project_override = true
  billing_project       = var.project_id
}

data "google_project" "this" {}

# Workload identity federation and the APIs Terraform itself calls. The service
# APIs (Cloud Run, Cloud SQL, …) are gcp/'s, enabled by the Terraform account.
resource "google_project_service" "bootstrap" {
  for_each = toset([
    "cloudresourcemanager.googleapis.com",
    "firebase.googleapis.com",
    "firebasehosting.googleapis.com",
    "iam.googleapis.com",
    "iamcredentials.googleapis.com",
    "serviceusage.googleapis.com",
    "sts.googleapis.com",
  ])

  service = each.value
  # Destroying the bootstrap must not switch off APIs other things still use.
  disable_on_destroy = false
}

# --- service accounts --------------------------------------------------------------

# One per program, never the default compute account (it starts with Editor).
resource "google_service_account" "terraform" {
  account_id   = "terraform"
  display_name = "Terraform (HCP Terraform workspace ${var.hcp_workspace_name})"
  depends_on   = [google_project_service.bootstrap]
}

resource "google_service_account" "api" {
  account_id   = "spry-api"
  display_name = "Spry API on Cloud Run (runtime)"
  depends_on   = [google_project_service.bootstrap]
}

resource "google_service_account" "build" {
  account_id   = "spry-build"
  display_name = "Cloud Build: builds the backend image"
  depends_on   = [google_project_service.bootstrap]
}

# LAB9 Part 0, minus Service Account User, which is granted below on the one
# account Terraform deploys as instead of on every account in the project.
resource "google_project_iam_member" "terraform" {
  for_each = toset([
    "roles/artifactregistry.admin",
    "roles/cloudsql.admin",
    "roles/run.admin",
    "roles/secretmanager.admin",
    "roles/serviceusage.serviceUsageAdmin",
  ])

  project = var.project_id
  role    = each.value
  member  = google_service_account.terraform.member
}

# Cloud Run checks that whoever deploys a service may act as its account.
resource "google_service_account_iam_member" "terraform_acts_as_api" {
  service_account_id = google_service_account.api.name
  role               = "roles/iam.serviceAccountUser"
  member             = google_service_account.terraform.member
}

# The API reaches Cloud SQL through the connector, which checks this role.
# Project-level only, so it lives here; the secret it reads is gcp/'s.
resource "google_project_iam_member" "api_sql_client" {
  project = var.project_id
  role    = "roles/cloudsql.client"
  member  = google_service_account.api.member
}

# --- Cloud Build ---------------------------------------------------------------------

# `make gcp-build` uploads backend/ here, and the build reads it back. Sources
# are kept a week, long enough to re-run a build.
resource "google_storage_bucket" "build_source" {
  name                        = "${var.project_id}-build-source"
  location                    = var.region
  uniform_bucket_level_access = true
  public_access_prevention    = "enforced"
  force_destroy               = true

  lifecycle_rule {
    condition {
      age = 7
    }
    action {
      type = "Delete"
    }
  }
}

resource "google_storage_bucket_iam_member" "build_reads_source" {
  bucket = google_storage_bucket.build_source.name
  role   = "roles/storage.objectViewer"
  member = google_service_account.build.member
}

# A build that runs as its own account writes its logs to Cloud Logging only.
# Pushing to the registry is granted on the repository, in gcp/.
resource "google_project_iam_member" "build_logs" {
  project = var.project_id
  role    = "roles/logging.logWriter"
  member  = google_service_account.build.member
}

# --- HCP Terraform → Google, without keys --------------------------------------------

# Deleted pools are kept for 30 days and their ids cannot be reused meanwhile.
resource "google_iam_workload_identity_pool" "hcp" {
  workload_identity_pool_id = "hcp-terraform"
  display_name              = "HCP Terraform"
  description               = "Runs of ${var.hcp_organization_name}/${var.hcp_workspace_name}"
  depends_on                = [google_project_service.bootstrap]
}

resource "google_iam_workload_identity_pool_provider" "hcp" {
  workload_identity_pool_id          = google_iam_workload_identity_pool.hcp.workload_identity_pool_id
  workload_identity_pool_provider_id = "hcp-terraform"
  display_name                       = "HCP Terraform"

  # HCP Terraform asks for the provider's own URL as the audience, which is
  # what an empty allowed_audiences accepts.
  oidc {
    issuer_uri = "https://${var.hcp_hostname}"
  }

  attribute_mapping = {
    "google.subject"                      = "assertion.sub"
    "attribute.terraform_organization_id" = "assertion.terraform_organization_id"
    "attribute.terraform_workspace_id"    = "assertion.terraform_workspace_id"
    "attribute.terraform_run_phase"       = "assertion.terraform_run_phase"
  }

  # Ids, not names: an organisation or workspace name can be freed and taken
  # by someone else; its id cannot.
  attribute_condition = join(" && ", [
    "assertion.terraform_organization_id == \"${var.hcp_organization_id}\"",
    "assertion.terraform_workspace_id == \"${var.hcp_workspace_id}\"",
  ])
}

# Only tokens from that one workspace may become the Terraform account.
resource "google_service_account_iam_member" "hcp_workload_identity_user" {
  service_account_id = google_service_account.terraform.name
  role               = "roles/iam.workloadIdentityUser"
  member             = "principalSet://iam.googleapis.com/${google_iam_workload_identity_pool.hcp.name}/attribute.terraform_workspace_id/${var.hcp_workspace_id}"
}

# --- Firebase ------------------------------------------------------------------------

# Adds Firebase to the project, which brings its default Hosting site
# (<project>.web.app). The site's files go up with `make gcp-deploy-frontend`.
resource "google_firebase_project" "this" {
  provider   = google-beta
  project    = var.project_id
  depends_on = [google_project_service.bootstrap]
}
