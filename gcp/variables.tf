variable "project_id" {
  type = string
}

variable "region" {
  type    = string
  default = "us-central1"
}

# --- database ------------------------------------------------------------------------

variable "db_tier" {
  type        = string
  default     = "db-f1-micro"
  description = "Shared-core db-f1-micro ($0.0105/h while running) or db-g1-small."
}

variable "db_disk_gb" {
  type        = number
  default     = 10
  description = "SSD, billed while the instance is stopped too."
}

variable "db_name" {
  type    = string
  default = "meetings"
}

variable "db_username" {
  type    = string
  default = "app"
}

# --- API -------------------------------------------------------------------------------

variable "api_max_instances" {
  type        = number
  default     = 2
  description = "A cap on cost and on connections to a 0.6 GB database."
}

variable "app_timezone" {
  type    = string
  default = "Europe/Kyiv"
}

variable "log_level" {
  type    = string
  default = "INFO"
}

# Sign-in stays on AWS (ADR 0008): the API checks Cognito's tokens. Neither
# value is secret; both are outputs of infra/.
variable "cognito_region" {
  type    = string
  default = "us-east-1"
}

variable "cognito_user_pool_id" {
  type = string
}

variable "cognito_client_id" {
  type = string
}
