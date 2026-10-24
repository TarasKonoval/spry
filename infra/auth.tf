# Sign-in for the meetings app (was infra/auth.yml): a Cognito user pool where
# people sign up with their email and a password, optionally federated with
# Google, plus the public app client the Next.js frontend signs in through. The
# backend accepts the access tokens this pool issues to that client.

locals {
  has_google = var.google_client_id != ""

  # Every URL the site is served from, each ending in "/": Cognito sends people
  # back there after signing in with Google or signing out.
  app_urls = concat(["${local.local_origin}/"], [for o in local.site_origins : "${o}/"])
}

resource "aws_cognito_user_pool" "main" {
  name           = "${var.project_name}-users"
  user_pool_tier = "ESSENTIALS"

  # People sign in with their email address; Cognito mails them a code to
  # confirm it on sign-up and to reset a forgotten password. Changing either of
  # these two replaces the pool, and every account in it.
  username_attributes      = ["email"]
  auto_verified_attributes = ["email"]

  username_configuration {
    case_sensitive = false
  }

  admin_create_user_config {
    allow_admin_create_user_only = false
  }

  account_recovery_setting {
    recovery_mechanism {
      name     = "verified_email"
      priority = 1
    }
  }

  password_policy {
    minimum_length                   = 8
    require_lowercase                = true
    require_uppercase                = true
    require_numbers                  = true
    require_symbols                  = false
    temporary_password_validity_days = 7
  }

  sign_in_policy {
    allowed_first_auth_factors = ["PASSWORD"]
  }

  schema {
    name                     = "email"
    attribute_data_type      = "String"
    required                 = true
    mutable                  = true
    developer_only_attribute = false

    string_attribute_constraints {
      min_length = "0"
      max_length = "2048"
    }
  }

  # Cognito's own mailer: free, but capped at 50 emails a day. Switch to SES
  # before real traffic arrives.
  email_configuration {
    email_sending_account = "COGNITO_DEFAULT"
  }

  lifecycle {
    prevent_destroy = true
  }
}

# Hosts the OAuth endpoints Google sign-in goes through:
# https://<prefix>.auth.<region>.amazoncognito.com
resource "aws_cognito_user_pool_domain" "main" {
  user_pool_id = aws_cognito_user_pool.main.id
  # Domain prefixes are unique per region across all accounts.
  domain                = "${var.project_name}-${local.account_id}"
  managed_login_version = 2
}

resource "aws_cognito_identity_provider" "google" {
  count = local.has_google ? 1 : 0

  user_pool_id  = aws_cognito_user_pool.main.id
  provider_name = "Google"
  provider_type = "Google"

  # Cognito fills in everything but the first three itself; they are listed so
  # the plan does not offer to remove them.
  provider_details = {
    client_id                     = var.google_client_id
    client_secret                 = var.google_client_secret
    authorize_scopes              = "openid email profile"
    attributes_url                = "https://people.googleapis.com/v1/people/me?personFields="
    attributes_url_add_attributes = "true"
    authorize_url                 = "https://accounts.google.com/o/oauth2/v2/auth"
    oidc_issuer                   = "https://accounts.google.com"
    token_request_method          = "POST"
    token_url                     = "https://www.googleapis.com/oauth2/v4/token"
  }

  attribute_mapping = {
    email          = "email"
    email_verified = "email_verified"
    name           = "name"
    username       = "sub"
  }
}

# Public client for the browser: no secret, SRP for passwords (the password
# never leaves the browser), and the authorization-code flow with PKCE for
# Google.
resource "aws_cognito_user_pool_client" "web" {
  name         = "${var.project_name}-web"
  user_pool_id = aws_cognito_user_pool.main.id
  # No generate_secret: leaving it out means no secret, and an import does not
  # record it, so writing "false" would force a new client (and new client id).

  explicit_auth_flows = ["ALLOW_USER_SRP_AUTH", "ALLOW_REFRESH_TOKEN_AUTH"]

  prevent_user_existence_errors                 = "ENABLED"
  enable_token_revocation                       = true
  enable_propagate_additional_user_context_data = false
  auth_session_validity                         = 3

  access_token_validity  = 1
  id_token_validity      = 1
  refresh_token_validity = 30

  token_validity_units {
    access_token  = "hours"
    id_token      = "hours"
    refresh_token = "days"
  }

  # Referencing the provider (its name) also makes the client wait for it.
  supported_identity_providers = concat(["COGNITO"], aws_cognito_identity_provider.google[*].provider_name)

  allowed_oauth_flows_user_pool_client = true
  allowed_oauth_flows                  = ["code"]
  allowed_oauth_scopes                 = ["openid", "email", "profile"]
  callback_urls                        = local.app_urls
  logout_urls                          = local.app_urls
}

resource "aws_cognito_managed_login_branding" "web" {
  user_pool_id                = aws_cognito_user_pool.main.id
  client_id                   = aws_cognito_user_pool_client.web.id
  use_cognito_provided_values = true
}
