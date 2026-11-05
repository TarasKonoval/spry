# The API on Cloud Run: backend/Dockerfile unchanged (uvicorn on 8000), no
# Lambda adapter. Terraform creates the service and the job from a placeholder
# image and then ignores the image; code arrives with make gcp-deploy-backend,
# as it does on AWS.

locals {
  placeholder_image = "us-docker.pkg.dev/cloudrun/container/hello"

  # What the service and the migrate job both need to reach the database.
  database_env = {
    APP_TIMEZONE = var.app_timezone
    LOG_LEVEL    = var.log_level
  }
}

resource "google_cloud_run_v2_service" "api" {
  name                = "spry-api"
  location            = var.region
  ingress             = "INGRESS_TRAFFIC_ALL"
  deletion_protection = false

  template {
    service_account = local.api_service_account
    timeout         = "30s"

    scaling {
      min_instance_count = 0
      max_instance_count = var.api_max_instances
    }

    volumes {
      name = "cloudsql"
      cloud_sql_instance {
        instances = [google_sql_database_instance.main.connection_name]
      }
    }

    containers {
      image = local.placeholder_image

      ports {
        container_port = 8000
      }

      resources {
        limits = {
          cpu    = "1"
          memory = "512Mi"
        }
        # Billed only while a request is in flight; the free tier counts that.
        cpu_idle          = true
        startup_cpu_boost = true
      }

      # Migrations run in the job below, not on every cold start.
      env {
        name  = "RUN_MIGRATIONS_ON_START"
        value = "false"
      }

      dynamic "env" {
        for_each = merge(local.database_env, {
          CORS_ORIGINS         = join(",", local.site_origins)
          COGNITO_REGION       = var.cognito_region
          COGNITO_USER_POOL_ID = var.cognito_user_pool_id
          COGNITO_CLIENT_ID    = var.cognito_client_id
        })
        content {
          name  = env.key
          value = env.value
        }
      }

      env {
        name = "DATABASE_URL"
        value_source {
          secret_key_ref {
            secret  = google_secret_manager_secret.database_url.secret_id
            version = "latest"
          }
        }
      }

      volume_mounts {
        name       = "cloudsql"
        mount_path = "/cloudsql"
      }
    }
  }

  lifecycle {
    ignore_changes = [
      template[0].containers[0].image,
      client,
      client_version,
    ]
  }

  depends_on = [
    google_secret_manager_secret_iam_member.api_reads_database_url,
    google_secret_manager_secret_version.database_url,
  ]
}

# Public, like the Lambda function URL: the API checks Cognito tokens itself,
# and Firebase Hosting's rewrite calls it without credentials.
resource "google_cloud_run_v2_service_iam_member" "public" {
  name     = google_cloud_run_v2_service.api.name
  location = google_cloud_run_v2_service.api.location
  role     = "roles/run.invoker"
  member   = "allUsers"
}

# Same image, run once: the entrypoint applies the migrations, then runs the
# job's args. make gcp-migrate runs it as is (alembic current); make gcp-seed
# passes `python -m app.seed <cognito-sub>` instead.
resource "google_cloud_run_v2_job" "migrate" {
  name                = "spry-migrate"
  location            = var.region
  deletion_protection = false

  template {
    task_count = 1

    template {
      service_account = local.api_service_account
      max_retries     = 0
      timeout         = "300s"

      volumes {
        name = "cloudsql"
        cloud_sql_instance {
          instances = [google_sql_database_instance.main.connection_name]
        }
      }

      containers {
        image = local.placeholder_image
        args  = ["alembic", "current"]

        env {
          name  = "RUN_MIGRATIONS_ON_START"
          value = "true"
        }

        dynamic "env" {
          for_each = local.database_env
          content {
            name  = env.key
            value = env.value
          }
        }

        env {
          name = "DATABASE_URL"
          value_source {
            secret_key_ref {
              secret  = google_secret_manager_secret.database_url.secret_id
              version = "latest"
            }
          }
        }

        volume_mounts {
          name       = "cloudsql"
          mount_path = "/cloudsql"
        }
      }
    }
  }

  lifecycle {
    ignore_changes = [
      template[0].template[0].containers[0].image,
      client,
      client_version,
    ]
  }

  depends_on = [
    google_secret_manager_secret_iam_member.api_reads_database_url,
    google_secret_manager_secret_version.database_url,
  ]
}
