# Non-secret values live in terraform.tfvars. The sensitive ones, and the
# personal email address, are set on the HCP Terraform workspace.

variable "project_name" {
  type        = string
  description = "Prefix for every resource name, and the PROJECT_NAME tag."
}

variable "region" {
  type    = string
  default = "us-east-1"
}

# --- sign-in (was infra/auth.yml) ----------------------------------------------

variable "frontend_port" {
  type        = number
  default     = 3000
  description = "Port of the local dev server, allowed as a Cognito redirect and a parser origin."
}

variable "frontend_stack_exists" {
  type        = bool
  default     = true
  description = "false in a new environment until the frontend stack exists: its AllowedOrigins then join the redirect URLs."
}

variable "google_client_id" {
  type        = string
  default     = ""
  description = "OAuth client id of a Google Cloud \"Web application\" client. Empty leaves Google sign-in out."
}

variable "google_client_secret" {
  type        = string
  default     = ""
  sensitive   = true
  description = "That Google client's secret. Set on the workspace, never in a file."
}

# --- weekly report (was infra/reports.yml) ---------------------------------------

variable "lambda_architecture" {
  type        = string
  default     = "x86_64"
  description = "Must match the platform of the backend image (AWS_LAMBDA_ARCH in the Makefile)."

  validation {
    condition     = contains(["x86_64", "arm64"], var.lambda_architecture)
    error_message = "lambda_architecture must be x86_64 or arm64."
  }
}

variable "image_tag" {
  type        = string
  default     = "latest"
  description = "Backend image tag a function is created from. After that the Makefile deploys code, and Terraform ignores image_uri."
}

variable "create_s3_endpoint" {
  type        = bool
  default     = true
  description = "false when the VPC already has an S3 gateway endpoint: a route table takes only one route to the S3 prefix list."
}

variable "db_name" {
  type    = string
  default = "meetings"
}

variable "db_username" {
  type    = string
  default = "app"
}

variable "db_port" {
  type    = number
  default = 5432
}

variable "db_password" {
  type        = string
  sensitive   = true
  description = "The Aurora master password, as passed to the backend stack. Set on the workspace."

  validation {
    condition     = can(regex("^[a-zA-Z0-9_-]{8,41}$", var.db_password))
    error_message = "db_password must be 8-41 characters of [a-zA-Z0-9_-]."
  }
}

variable "app_timezone" {
  type        = string
  default     = "Europe/Kyiv"
  description = "Defines the ISO weeks of the report and the schedule's clock."
}

variable "schedule_expression" {
  type        = string
  default     = "cron(0 7 ? * MON *)"
  description = "When the report is built, in app_timezone. Test with rate(5 minutes), then set it back: every run wakes Aurora."
}

variable "reports_email" {
  type        = string
  description = "Verified SES email identity, used as both the sender and the recipient of the report. Set on the workspace."

  validation {
    condition     = can(regex("^[^@\\s]+@[^@\\s]+\\.[^@\\s]+$", var.reports_email))
    error_message = "reports_email must be one email address."
  }
}

variable "log_level" {
  type    = string
  default = "INFO"

  validation {
    condition     = contains(["DEBUG", "INFO", "WARNING", "ERROR"], var.log_level)
    error_message = "log_level must be DEBUG, INFO, WARNING or ERROR."
  }
}

# --- agenda parser (was infra/ai.yml) --------------------------------------------

variable "parser_model" {
  type        = string
  description = "Bedrock model id (PARSER_MODEL)."
}

# --- migration -------------------------------------------------------------------

variable "legacy_role_names" {
  type        = map(string)
  default     = {}
  description = <<-EOT
    IAM role names CloudFormation generated, keyed builder, mailer, schedule,
    parser. A role's name forces replacement, so the imported roles keep them;
    a new environment leaves this empty and gets readable names.
  EOT
}
