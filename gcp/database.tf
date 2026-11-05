# Cloud SQL for PostgreSQL: the counterpart of Aurora, except that it never
# pauses. It bills by the hour until it is stopped (make gcp-db-stop).

resource "google_sql_database_instance" "main" {
  name             = "spry-db"
  database_version = "POSTGRES_16"
  region           = var.region

  # Lab data, re-created by migrations + seed: `terraform destroy` must work.
  # A deleted instance's name cannot be reused for about a week.
  deletion_protection = false

  settings {
    tier = var.db_tier
    # The shared-core tiers exist only in the Enterprise edition.
    edition           = "ENTERPRISE"
    availability_type = "ZONAL"
    activation_policy = "ALWAYS"

    disk_type       = "PD_SSD"
    disk_size       = var.db_disk_gb
    disk_autoresize = false

    deletion_protection_enabled = false

    backup_configuration {
      enabled = false
    }

    # A public address with no authorised networks: only the Cloud SQL connector
    # (Cloud Run's /cloudsql socket, the Auth Proxy) gets in, and it checks IAM.
    ip_configuration {
      ipv4_enabled = true
      ssl_mode     = "ENCRYPTED_ONLY"
    }
  }

  lifecycle {
    # Started and stopped with gcloud (make gcp-db-start / gcp-db-stop), so the
    # next plan does not start a stopped instance again.
    ignore_changes = [settings[0].activation_policy]
  }

  depends_on = [google_project_service.apis]
}

resource "google_sql_database" "app" {
  name     = var.db_name
  instance = google_sql_database_instance.main.name
  # Deleting the instance deletes the database; dropping it first fails while
  # anything is connected.
  deletion_policy = "ABANDON"
}

# Letters and digits only, so it goes into the URL below without escaping.
resource "random_password" "db" {
  length  = 32
  special = false
}

resource "google_sql_user" "app" {
  name     = var.db_username
  instance = google_sql_database_instance.main.name
  password = random_password.db.result
  # The user owns the tables, and PostgreSQL refuses to drop it; the instance
  # goes with everything in it.
  deletion_policy = "ABANDON"
}

# The whole DATABASE_URL the app already reads, pointing at the socket Cloud Run
# mounts for the instance. The password exists only here and in the state.
resource "google_secret_manager_secret" "database_url" {
  secret_id = "spry-database-url"

  replication {
    auto {}
  }

  depends_on = [google_project_service.apis]
}

resource "google_secret_manager_secret_version" "database_url" {
  secret      = google_secret_manager_secret.database_url.id
  secret_data = "postgresql+asyncpg://${google_sql_user.app.name}:${random_password.db.result}@/${google_sql_database.app.name}?host=/cloudsql/${google_sql_database_instance.main.connection_name}"
}

resource "google_secret_manager_secret_iam_member" "api_reads_database_url" {
  secret_id = google_secret_manager_secret.database_url.id
  role      = "roles/secretmanager.secretAccessor"
  member    = "serviceAccount:${local.api_service_account}"
}
