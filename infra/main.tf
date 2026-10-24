# Values from the stacks that stay on CloudFormation (ecr, backend, frontend),
# and names shared by more than one file.

data "aws_caller_identity" "current" {}
data "aws_region" "current" {}
data "aws_partition" "current" {}

data "aws_cloudformation_stack" "ecr" {
  name = "${var.project_name}-ecr"
}

data "aws_cloudformation_stack" "backend" {
  name = "${var.project_name}-backend"
}

data "aws_cloudformation_stack" "frontend" {
  count = var.frontend_stack_exists ? 1 : 0
  name  = "${var.project_name}-frontend"
}

# The report builder sits in the API function's VPC, subnets and security group,
# which the database already accepts on 5432.
data "aws_lambda_function" "api" {
  function_name = data.aws_cloudformation_stack.backend.outputs["FunctionName"]
}

# The image a function is created from. Afterwards the Makefile deploys code
# with update-function-code, and Terraform ignores image_uri.
data "aws_ecr_image" "backend" {
  repository_name = local.ecr_repository_name
  image_tag       = var.image_tag
}

locals {
  account_id = data.aws_caller_identity.current.account_id
  region     = data.aws_region.current.region
  partition  = data.aws_partition.current.partition

  ecr_repository_uri  = data.aws_cloudformation_stack.ecr.outputs["RepositoryUri"]
  ecr_repository_name = split("/", local.ecr_repository_uri)[1]
  backend_image_uri   = "${local.ecr_repository_uri}@${data.aws_ecr_image.backend.image_digest}"

  vpc_id             = data.aws_lambda_function.api.vpc_config[0].vpc_id
  subnet_ids         = data.aws_lambda_function.api.vpc_config[0].subnet_ids
  security_group_ids = data.aws_lambda_function.api.vpc_config[0].security_group_ids
  db_endpoint        = data.aws_cloudformation_stack.backend.outputs["DatabaseEndpoint"]

  # The site's origins, e.g. ["https://d123.cloudfront.net"], empty before the
  # frontend exists.
  site_origins = var.frontend_stack_exists ? split(",", data.aws_cloudformation_stack.frontend[0].outputs["AllowedOrigins"]) : []
  local_origin = "http://localhost:${var.frontend_port}"

  # Named, not referenced, so the roles do not depend on the bucket.
  reports_bucket_name = "${var.project_name}-reports-${local.account_id}"

  role_names = {
    builder  = lookup(var.legacy_role_names, "builder", "${var.project_name}-report-builder")
    mailer   = lookup(var.legacy_role_names, "mailer", "${var.project_name}-report-mailer")
    schedule = lookup(var.legacy_role_names, "schedule", "${var.project_name}-weekly-report")
    parser   = lookup(var.legacy_role_names, "parser", "${var.project_name}-agenda-parser")
  }

  lambda_assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}
