# Weekly meetings report (was infra/reports.yml): an EventBridge Scheduler
# schedule (and `make report-now`) puts a request on an SQS queue with a
# dead-letter queue; the report-builder Lambda (the backend image with another
# command) in the backend's VPC reads Aurora and writes reports/<week>.csv to a
# private bucket through a free S3 gateway endpoint, since the VPC has no NAT.
# The new object triggers the report-mailer Lambda outside the VPC, which emails
# the CSV through SES.
#
# In CloudFormation the bucket, the mailer's permission and the notification
# depended on each other in a circle, broken by naming the bucket. Here they are
# three resources with plain references, and the notification simply comes last.

# --- storage ---------------------------------------------------------------------

resource "aws_s3_bucket" "reports" {
  bucket = local.reports_bucket_name

  # Every report lives here. Emptying and deleting it is a deliberate act.
  lifecycle {
    prevent_destroy = true
  }
}

resource "aws_s3_bucket_public_access_block" "reports" {
  bucket                  = aws_s3_bucket.reports.id
  block_public_acls       = true
  ignore_public_acls      = true
  block_public_policy     = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_ownership_controls" "reports" {
  bucket = aws_s3_bucket.reports.id

  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "reports" {
  bucket = aws_s3_bucket.reports.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
    bucket_key_enabled       = false
    blocked_encryption_types = ["SSE-C"]
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "reports" {
  bucket = aws_s3_bucket.reports.id

  rule {
    id     = "expire-reports"
    status = "Enabled"

    filter {
      prefix = "reports/"
    }

    expiration {
      days = 90
    }
  }

  rule {
    id     = "abort-incomplete-uploads"
    status = "Enabled"

    filter {
      prefix = ""
    }

    abort_incomplete_multipart_upload {
      days_after_initiation = 1
    }
  }
}

# An event, not a command: the builder does not know the mailer exists.
resource "aws_s3_bucket_notification" "reports" {
  bucket = aws_s3_bucket.reports.id

  lambda_function {
    lambda_function_arn = aws_lambda_function.mailer.arn
    events              = ["s3:ObjectCreated:*"]
    filter_prefix       = "reports/"
    filter_suffix       = ".csv"
  }

  # S3 checks that it may invoke the mailer when the notification is set.
  depends_on = [aws_lambda_permission.mailer_s3]
}

# Without it, the builder's PutObject has no route out of the VPC and hangs
# until the function times out. Gateway endpoints are free.
data "aws_route_tables" "builder_subnets" {
  vpc_id = local.vpc_id

  filter {
    name   = "association.subnet-id"
    values = local.subnet_ids
  }
}

data "aws_route_tables" "vpc_main" {
  vpc_id = local.vpc_id

  filter {
    name   = "association.main"
    values = ["true"]
  }
}

resource "aws_vpc_endpoint" "s3" {
  count = var.create_s3_endpoint ? 1 : 0

  vpc_id            = local.vpc_id
  service_name      = "com.amazonaws.${local.region}.s3"
  vpc_endpoint_type = "Gateway"
  route_table_ids   = sort(distinct(concat(data.aws_route_tables.builder_subnets.ids, data.aws_route_tables.vpc_main.ids)))
}

# --- builder ---------------------------------------------------------------------

resource "aws_iam_role" "builder" {
  name               = local.role_names.builder
  assume_role_policy = local.lambda_assume_role_policy
}

# Write logs, and manage the network interfaces a VPC function needs.
resource "aws_iam_role_policy_attachment" "builder_vpc" {
  role       = aws_iam_role.builder.name
  policy_arn = "arn:${local.partition}:iam::aws:policy/service-role/AWSLambdaVPCAccessExecutionRole"
}

resource "aws_iam_role_policy" "builder_write_reports" {
  name = "write-reports"
  role = aws_iam_role.builder.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = "s3:PutObject"
      Resource = "arn:${local.partition}:s3:::${local.reports_bucket_name}/reports/*"
    }]
  })
}

# The Lambda service polls the queue with the function's role; the function
# itself never connects to SQS.
resource "aws_iam_role_policy" "builder_consume_requests" {
  name = "consume-report-requests"
  role = aws_iam_role.builder.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = [
        "sqs:ReceiveMessage",
        "sqs:DeleteMessage",
        "sqs:GetQueueAttributes",
        "sqs:ChangeMessageVisibility",
      ]
      Resource = aws_sqs_queue.report_requests.arn
    }]
  })
}

resource "aws_cloudwatch_log_group" "builder" {
  name              = "/aws/lambda/${var.project_name}-report-builder"
  retention_in_days = 7
}

resource "aws_lambda_function" "builder" {
  function_name = "${var.project_name}-report-builder"
  description   = "Builds the weekly meetings report and saves it to S3"
  package_type  = "Image"
  image_uri     = local.backend_image_uri
  architectures = [var.lambda_architecture]
  role          = aws_iam_role.builder.arn
  memory_size   = 512
  # A paused cluster takes ~15 s to resume on the first connection.
  timeout = 60

  image_config {
    command = ["app.reports.lambda_handler.handler"]
  }

  logging_config {
    log_format = "Text"
    log_group  = aws_cloudwatch_log_group.builder.name
  }

  vpc_config {
    subnet_ids         = local.subnet_ids
    security_group_ids = local.security_group_ids
  }

  environment {
    variables = {
      # NOTE: readable in the function configuration and in the state, as on the API function.
      DATABASE_URL   = "postgresql+asyncpg://${var.db_username}:${var.db_password}@${local.db_endpoint}:${var.db_port}/${var.db_name}"
      APP_TIMEZONE   = var.app_timezone
      LOG_LEVEL      = var.log_level
      REPORTS_BUCKET = local.reports_bucket_name
    }
  }

  # The code is deployed by the Makefile (aws lambda update-function-code).
  lifecycle {
    ignore_changes = [image_uri]
  }
}

# --- queue -----------------------------------------------------------------------

resource "aws_sqs_queue" "report_requests_dlq" {
  name = "${var.project_name}-report-requests-dlq"
  # The longest SQS allows: time to notice, fix the builder and redrive.
  message_retention_seconds = 1209600
  max_message_size          = 1048576
  sqs_managed_sse_enabled   = true

  lifecycle {
    prevent_destroy = true
  }
}

resource "aws_sqs_queue" "report_requests" {
  name = "${var.project_name}-report-requests"
  # Six times the builder's timeout: a message must not become visible again,
  # and start a second builder, while the first is still running.
  visibility_timeout_seconds = 360
  max_message_size           = 1048576
  sqs_managed_sse_enabled    = true

  redrive_policy = jsonencode({
    deadLetterTargetArn = aws_sqs_queue.report_requests_dlq.arn
    maxReceiveCount     = 3
  })

  lifecycle {
    prevent_destroy = true
  }
}

resource "aws_lambda_event_source_mapping" "builder" {
  event_source_arn = aws_sqs_queue.report_requests.arn
  function_name    = aws_lambda_function.builder.arn
  batch_size       = 1

  # At most two builders at once (the lowest SQS allows), so a burst of requests
  # waits in the queue instead of using up the account's ten.
  scaling_config {
    maximum_concurrency = 2
  }
}

# --- mailer ----------------------------------------------------------------------

# Creating it makes SES email a verification link to the address; nothing can
# be sent until it is clicked. Destroying it would mean verifying again.
resource "aws_sesv2_email_identity" "reports" {
  email_identity = var.reports_email

  lifecycle {
    prevent_destroy = true
  }
}

resource "aws_iam_role" "mailer" {
  name               = local.role_names.mailer
  assume_role_policy = local.lambda_assume_role_policy
}

resource "aws_iam_role_policy_attachment" "mailer_basic" {
  role       = aws_iam_role.mailer.name
  policy_arn = "arn:${local.partition}:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

# Read-only on S3, on purpose: a function triggered by new objects in reports/
# that wrote into reports/ would call itself forever.
resource "aws_iam_role_policy" "mailer" {
  name = "read-reports-and-send"
  role = aws_iam_role.mailer.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = "s3:GetObject"
        Resource = "arn:${local.partition}:s3:::${local.reports_bucket_name}/reports/*"
      },
      {
        Effect   = "Allow"
        Action   = ["ses:SendEmail", "ses:SendRawEmail"]
        Resource = "arn:${local.partition}:ses:${local.region}:${local.account_id}:identity/${var.reports_email}"
      },
    ]
  })
}

resource "aws_cloudwatch_log_group" "mailer" {
  name              = "/aws/lambda/${var.project_name}-report-mailer"
  retention_in_days = 7
}

# One file, so mailer.py imports nothing from app. It lands as index.py, where
# CloudFormation's inline ZipFile put it, so the handler stays index.handler.
data "archive_file" "mailer" {
  type        = "zip"
  output_path = "${path.module}/.build/mailer.zip"

  source {
    content  = file("${path.module}/../backend/app/reports/mailer.py")
    filename = "index.py"
  }
}

# Outside the VPC (no vpc_config): it needs SES on the internet, and never the
# database.
resource "aws_lambda_function" "mailer" {
  function_name    = "${var.project_name}-report-mailer"
  description      = "Emails each new weekly report through SES"
  runtime          = "python3.12"
  handler          = "index.handler"
  architectures    = ["arm64"]
  role             = aws_iam_role.mailer.arn
  memory_size      = 128
  timeout          = 30
  filename         = data.archive_file.mailer.output_path
  source_code_hash = data.archive_file.mailer.output_base64sha256

  logging_config {
    log_format = "Text"
    log_group  = aws_cloudwatch_log_group.mailer.name
  }

  environment {
    variables = {
      REPORTS_FROM = var.reports_email
      REPORTS_TO   = var.reports_email
    }
  }

  # Migration PR only: CloudFormation's zip of the same code has another hash.
  # Remove in the next PR, whose plan then redeploys mailer.py once.
  lifecycle {
    ignore_changes = [filename, source_code_hash]
  }
}

# Re-created, not imported: CloudFormation's statement id was generated. The old
# statement was removed by hand once this one existed (ADR 0007).
resource "aws_lambda_permission" "mailer_s3" {
  statement_id   = "AllowS3InvokeFromReportsBucket"
  function_name  = aws_lambda_function.mailer.function_name
  action         = "lambda:InvokeFunction"
  principal      = "s3.amazonaws.com"
  source_arn     = aws_s3_bucket.reports.arn
  source_account = local.account_id
}

# --- schedule --------------------------------------------------------------------

resource "aws_iam_role" "schedule" {
  name = local.role_names.schedule

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "scheduler.amazonaws.com" }
      Action    = "sts:AssumeRole"
      Condition = {
        StringEquals = { "aws:SourceAccount" = local.account_id }
      }
    }]
  })
}

resource "aws_iam_role_policy" "schedule" {
  name = "send-report-requests"
  role = aws_iam_role.schedule.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = "sqs:SendMessage"
      Resource = aws_sqs_queue.report_requests.arn
    }]
  })
}

# Schedules take no tags.
resource "aws_scheduler_schedule" "weekly" {
  name        = "${var.project_name}-weekly-report"
  group_name  = "default"
  description = "Build last week's meetings report every Monday morning"

  schedule_expression = var.schedule_expression
  # Without it the cron runs in UTC, an hour off for half the year.
  schedule_expression_timezone = var.app_timezone
  state                        = "ENABLED"

  flexible_time_window {
    mode = "OFF"
  }

  # A command on the queue, not a call to the function: retries and the
  # dead-letter queue now cover a slow Aurora resume.
  target {
    arn      = aws_sqs_queue.report_requests.arn
    role_arn = aws_iam_role.schedule.arn
    # No week: the builder takes the one before the current week. A literal,
    # not jsonencode(): the string is compared as written.
    input = "{\"week\": null, \"source\": \"schedule\"}"

    retry_policy {
      maximum_event_age_in_seconds = 86400
      maximum_retry_attempts       = 185
    }
  }
}
