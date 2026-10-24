# Paste an agenda (was infra/ai.yml): the agenda-parser Lambda (the backend
# image with another command) behind its own function URL. It runs outside the
# VPC, checks the Cognito access token, calls Claude through Amazon Bedrock and
# returns a suggested agenda as JSON. It never writes anything: the browser
# saves through the API.

resource "aws_iam_role" "parser" {
  name               = local.role_names.parser
  assume_role_policy = local.lambda_assume_role_policy
}

# Logs only: no VPC, no database, no S3.
resource "aws_iam_role_policy_attachment" "parser_basic" {
  role       = aws_iam_role.parser.name
  policy_arn = "arn:${local.partition}:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

# No API key to store or leak: the role is what may call the model.
# "*" for now; narrowing it is one of the lab's discussion questions.
resource "aws_iam_role_policy" "parser" {
  name = "invoke-claude"
  role = aws_iam_role.parser.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = "bedrock-mantle:CreateInference"
        Resource = "*"
      },
      # Sonnet 4.6 is served by bedrock-runtime (InvokeModel), through its
      # global inference profile: the call needs the profile and the foundation
      # model in every Region the profile may route to. The global profile's
      # models include one ARN with no Region at all.
      {
        Effect = "Allow"
        Action = "bedrock:InvokeModel"
        Resource = [
          "arn:${local.partition}:bedrock:${local.region}:${local.account_id}:inference-profile/global.anthropic.claude-sonnet-4-6",
          "arn:${local.partition}:bedrock:*::foundation-model/anthropic.claude-sonnet-4-6",
          "arn:${local.partition}:bedrock:::foundation-model/anthropic.claude-sonnet-4-6",
        ]
      },
    ]
  })
}

resource "aws_cloudwatch_log_group" "parser" {
  name              = "/aws/lambda/${var.project_name}-agenda-parser"
  retention_in_days = 7
}

# Outside the VPC (no vpc_config): Bedrock and Cognito's JWKS are on the
# internet, and the function never needs the database. Idle, it costs nothing.
resource "aws_lambda_function" "parser" {
  function_name = "${var.project_name}-agenda-parser"
  description   = "Parses pasted text into a suggested meeting agenda with Claude on Bedrock"
  package_type  = "Image"
  image_uri     = local.backend_image_uri
  architectures = [var.lambda_architecture]
  role          = aws_iam_role.parser.arn
  memory_size   = 512
  # Two model calls at most (one retry), each capped at 25 s by the SDK client.
  timeout = 30

  image_config {
    command = ["app.ai.agenda_lambda.handler"]
  }

  logging_config {
    log_format = "Text"
    log_group  = aws_cloudwatch_log_group.parser.name
  }

  environment {
    variables = {
      PARSER_MODEL = var.parser_model
      LOG_LEVEL    = var.log_level
      # No COGNITO_JWKS: unlike the API, this function can fetch them.
      COGNITO_REGION       = local.region
      COGNITO_USER_POOL_ID = aws_cognito_user_pool.main.id
      COGNITO_CLIENT_ID    = aws_cognito_user_pool_client.web.id
    }
  }

  # The code is deployed by the Makefile (aws lambda update-function-code).
  lifecycle {
    ignore_changes = [image_uri]
  }
}

# Public, like the API's: the handler checks the Cognito token on every call,
# because every call costs money. Unlike the API, CORS lives here: the handler is
# a plain function with no middleware. Imported: a new URL would have to be
# rebuilt into the frontend (NEXT_PUBLIC_PARSER_URL).
resource "aws_lambda_function_url" "parser" {
  function_name      = aws_lambda_function.parser.function_name
  authorization_type = "NONE"
  invoke_mode        = "BUFFERED"

  cors {
    allow_origins = concat(local.site_origins, [local.local_origin])
    allow_methods = ["POST"]
    allow_headers = ["authorization", "content-type"]
    max_age       = 300
  }
}

# Both re-created, not imported: CloudFormation's statement ids were generated.
# The old statements were removed by hand once these existed (ADR 0007).
resource "aws_lambda_permission" "parser_url" {
  statement_id           = "FunctionURLAllowPublicAccess"
  function_name          = aws_lambda_function.parser.function_name
  action                 = "lambda:InvokeFunctionUrl"
  principal              = "*"
  function_url_auth_type = "NONE"
}

resource "aws_lambda_permission" "parser_url_invoke" {
  statement_id             = "FunctionURLAllowInvokeAction"
  function_name            = aws_lambda_function.parser.function_name
  action                   = "lambda:InvokeFunction"
  principal                = "*"
  invoked_via_function_url = true
}
