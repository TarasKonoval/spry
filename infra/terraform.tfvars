# Non-secret values only. db_password, google_client_secret and reports_email
# are set on the HCP Terraform workspace (successfulsuccess-dev).

project_name = "successfulsuccess"
region       = "us-east-1"

# Sign-in
frontend_port         = 3000
frontend_stack_exists = true
google_client_id      = "332442046477-10ro1fuqjfi2l8jh3aa9ac8np3q0gn1r.apps.googleusercontent.com"

# Weekly report
lambda_architecture = "x86_64"
create_s3_endpoint  = true
db_name             = "meetings"
db_username         = "app"
db_port             = 5432
app_timezone        = "Europe/Kyiv"
schedule_expression = "cron(0 7 ? * MON *)"
log_level           = "INFO"

# Agenda parser: what the ai stack was deployed with, not the Makefile's default.
parser_model = "global.anthropic.claude-sonnet-4-6"

# The roles CloudFormation named; renaming one replaces it. Drop an entry, in a
# PR of its own, to give that role a readable name.
legacy_role_names = {
  builder  = "successfulsuccess-reports-BuilderRole-2HFoDuxA2uTU"
  mailer   = "successfulsuccess-reports-MailerRole-SxcS5FlQmpeW"
  schedule = "successfulsuccess-reports-ScheduleRole-o4bBcZm0urtA"
  parser   = "successfulsuccess-ai-ParserRole-T69YZPK2DMcd"
}
