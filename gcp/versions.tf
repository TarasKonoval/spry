terraform {
  required_version = ">= 1.10"

  # Plans and applies run in HCP Terraform as the `terraform` service account,
  # through workload identity federation (TFC_GCP_* on the workspace, created by
  # gcp/bootstrap). The workspace is separate from infra/'s, so one plan cannot
  # break both clouds; its working directory is gcp.
  cloud {
    organization = "ooad-taraskonoval"

    workspaces {
      name = "successfulsuccess-gcp-dev"
    }
  }

  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 7.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
  }
}

provider "google" {
  project = var.project_id
  region  = var.region

  default_labels = {
    project    = "spry"
    managed-by = "terraform"
  }
}
