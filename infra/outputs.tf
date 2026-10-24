# Everything the Makefile and the frontend build read, under the names of the
# old stack outputs in snake_case.

# --- sign-in ---------------------------------------------------------------------

output "user_pool_id" {
  value = aws_cognito_user_pool.main.id
}

output "user_pool_client_id" {
  value = aws_cognito_user_pool_client.web.id
}

output "issuer" {
  description = "The \"iss\" of every token; its signing keys are at <issuer>/.well-known/jwks.json"
  value       = "https://cognito-idp.${local.region}.amazonaws.com/${aws_cognito_user_pool.main.id}"
}

output "hosted_domain" {
  description = "Cognito's OAuth domain, which the frontend sends Google sign-in through"
  value       = "${aws_cognito_user_pool_domain.main.domain}.auth.${local.region}.amazoncognito.com"
}

output "google_redirect_uri" {
  description = "Add this to the Google client's \"Authorized redirect URIs\""
  value       = "https://${aws_cognito_user_pool_domain.main.domain}.auth.${local.region}.amazoncognito.com/oauth2/idpresponse"
}

output "google_enabled" {
  value = local.has_google ? "true" : "false"
}

# --- weekly report ---------------------------------------------------------------

output "reports_bucket_name" {
  value = aws_s3_bucket.reports.bucket
}

output "builder_function_name" {
  value = aws_lambda_function.builder.function_name
}

output "builder_log_group_name" {
  value = aws_cloudwatch_log_group.builder.name
}

output "schedule_name" {
  value = aws_scheduler_schedule.weekly.name
}

output "mailer_function_name" {
  value = aws_lambda_function.mailer.function_name
}

output "mailer_log_group_name" {
  value = aws_cloudwatch_log_group.mailer.name
}

output "queue_url" {
  value = aws_sqs_queue.report_requests.url
}

output "dead_letter_queue_url" {
  value = aws_sqs_queue.report_requests_dlq.url
}

output "s3_endpoint_id" {
  value = var.create_s3_endpoint ? aws_vpc_endpoint.s3[0].id : "existing"
}

# --- agenda parser ---------------------------------------------------------------

output "parser_url" {
  description = "The parser's function URL, without its trailing slash (NEXT_PUBLIC_PARSER_URL)"
  value       = trimsuffix(aws_lambda_function_url.parser.function_url, "/")
}

output "parser_function_name" {
  value = aws_lambda_function.parser.function_name
}

output "parser_log_group_name" {
  value = aws_cloudwatch_log_group.parser.name
}
