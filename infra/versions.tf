terraform {
  required_version = ">= 1.10"

  # Plans and applies run in HCP Terraform with dynamic AWS credentials
  # (TFC_AWS_PROVIDER_AUTH, TFC_AWS_RUN_ROLE_ARN on the workspace). The
  # workspace's working directory is infra, so a CLI-driven run uploads the
  # repository root: see /.terraformignore.
  cloud {
    organization = "ooad-taraskonoval"

    workspaces {
      name = "successfulsuccess-dev"
    }
  }

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
    archive = {
      source  = "hashicorp/archive"
      version = "~> 2.7"
    }
  }
}

provider "aws" {
  region = var.region

  # On every resource that takes tags: PROJECT_NAME, the tag every stack
  # carried, and who manages the resource now.
  default_tags {
    tags = {
      PROJECT_NAME = var.project_name
      ManagedBy    = "terraform"
    }
  }
}
