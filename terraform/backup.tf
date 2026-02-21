# --- Restic backups vers S3 (chiffre, retention 7j/4w/12m) ---
# Desactiver : enable_backup = false

resource "random_password" "backup" {
  count   = var.enable_backup ? 1 : 0
  length  = 32
  special = false
}

resource "scaleway_object_bucket" "backup" {
  count    = var.enable_backup ? 1 : 0
  provider = scaleway.project
  name     = "openclaw-backup-${local.project_id}"
  tags = {
    managed-by = "opentofu"
  }

  lifecycle_rule {
    enabled = true
    expiration {
      days = 365
    }
  }
}

module "iam_backup" {
  count       = var.enable_backup ? 1 : 0
  source      = "./modules/iam-service-account"
  name        = "openclaw-backup"
  description = "Application IAM dediee aux backups restic vers S3"
  project_id  = local.project_id
  project_rules = [{
    project_ids          = [local.project_id]
    permission_set_names = ["ObjectStorageFullAccess"]
  }]
}
