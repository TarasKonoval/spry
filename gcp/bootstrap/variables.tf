variable "project_id" {
  type = string
}

variable "region" {
  type    = string
  default = "us-central1"
}

variable "hcp_hostname" {
  type    = string
  default = "app.terraform.io"
}

variable "hcp_organization_name" {
  type        = string
  description = "Only labels the pool; the condition uses hcp_organization_id."
}

variable "hcp_organization_id" {
  type        = string
  description = "HCP Terraform organisation id (org-…): Organization settings → General."

  validation {
    condition     = can(regex("^org-[A-Za-z0-9]+$", var.hcp_organization_id))
    error_message = "hcp_organization_id looks like org-AbC123…"
  }
}

variable "hcp_workspace_name" {
  type        = string
  description = "Only labels the pool and the account; the condition uses hcp_workspace_id."
}

variable "hcp_workspace_id" {
  type        = string
  description = "Id of the gcp/ workspace (ws-…): the workspace's overview page."

  validation {
    condition     = can(regex("^ws-[A-Za-z0-9]+$", var.hcp_workspace_id))
    error_message = "hcp_workspace_id looks like ws-AbC123…"
  }
}
