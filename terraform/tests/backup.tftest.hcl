mock_provider "scaleway" {}
mock_provider "tls" {}
mock_provider "random" {}
mock_provider "github" {}
mock_provider "archive" {}

override_resource {
  target = scaleway_account_project.openclaw
  values = {
    id              = "11111111-1111-1111-1111-111111111111"
    organization_id = "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"
  }
}
override_resource {
  target = module.iam_openclaw.scaleway_iam_application.this
  values = { id = "22222222-2222-2222-2222-222222222222" }
}
override_resource {
  target = module.iam_cicd.scaleway_iam_application.this
  values = { id = "33333333-3333-3333-3333-333333333333" }
}
override_resource {
  target = module.iam_killswitch.scaleway_iam_application.this
  values = { id = "55555555-5555-5555-5555-555555555555" }
}
override_resource {
  target = module.iam_backup.scaleway_iam_application.this
  values = { id = "66666666-6666-6666-6666-666666666666" }
}
override_resource {
  target = module.iam_openclaw.scaleway_iam_api_key.primary
  values = { secret_key = "00000000-0000-0000-0000-000000000000" }
}
override_resource {
  target = scaleway_instance_server.openclaw
  values = { id = "fr-par-1/44444444-4444-4444-4444-444444444444" }
}

variables {
  scw_access_key             = "SCWTEST0000000000000"
  scw_secret_key             = "00000000-0000-0000-0000-000000000001"
  scw_organization_id        = "00000000-0000-0000-0000-000000000000"
  admin_ip_cidr              = "203.0.113.42/32"
  admin_email                = "admin@example.com"
  domain_name                = "example.com"
  openclaw_version           = "1.0.0"
  pomerium_idp_client_id     = "test-client-id"
  pomerium_idp_client_secret = "test-client-secret"
  encryption_passphrase      = "test-passphrase-minimum-16-chars"
}

# --- Backup bucket lifecycle ---

run "backup_bucket_has_lifecycle_rule" {
  command = plan
  assert {
    condition     = scaleway_object_bucket.backup[0].lifecycle_rule[0].enabled == true
    error_message = "Backup bucket lifecycle rule should be enabled"
  }
  assert {
    condition     = scaleway_object_bucket.backup[0].lifecycle_rule[0].expiration[0].days == 365
    error_message = "Backup bucket lifecycle expiration should be 365 days"
  }
}

# --- Backup bucket name ---

run "backup_bucket_name_prefix" {
  command = plan
  assert {
    condition     = startswith(scaleway_object_bucket.backup[0].name, "openclaw-backup-")
    error_message = "Backup bucket name should start with openclaw-backup-"
  }
}

# --- Backup IAM module ---

run "backup_iam_module_exists" {
  command = plan
  assert {
    condition     = module.iam_backup[0].application_id != ""
    error_message = "Backup IAM module should create an application"
  }
}

# --- Backup password parameters ---

run "backup_password_params" {
  command = plan
  assert {
    condition     = random_password.backup[0].length == 32
    error_message = "Backup password length should be 32"
  }
  assert {
    condition     = random_password.backup[0].special == false
    error_message = "Backup password should not include special characters"
  }
}

# --- Backup outputs when enabled ---

run "backup_outputs_when_enabled" {
  command = plan
  assert {
    condition     = output.backup_password != "disabled"
    error_message = "Backup password output should not be disabled when backup enabled"
  }
  assert {
    condition     = output.backup_repository != "disabled"
    error_message = "Backup repository output should not be disabled when backup enabled"
  }
}

# --- Backup repository URL format ---

run "backup_repository_url_format" {
  command = plan
  assert {
    condition     = startswith(output.backup_repository, "s3:https://s3.fr-par.scw.cloud/openclaw-backup-")
    error_message = "Backup repository URL should start with s3:https://s3.fr-par.scw.cloud/openclaw-backup-"
  }
}
