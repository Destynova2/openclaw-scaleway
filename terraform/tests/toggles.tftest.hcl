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
  scw_access_key      = "SCWTEST0000000000000"
  scw_secret_key      = "00000000-0000-0000-0000-000000000001"
  scw_organization_id = "00000000-0000-0000-0000-000000000000"
  admin_ip_cidr       = "203.0.113.42/32"
  admin_email         = "admin@example.com"
  domain_name         = "example.com"
  openclaw_version    = "1.0.0"
  encryption_passphrase = "test-passphrase-minimum-16-chars"
}

# --- All modules disabled ---

run "all_disabled_plan_succeeds" {
  command = plan
  variables {
    enable_pomerium  = false
    enable_killswitch = false
    enable_monitoring = false
    enable_backup     = false
  }
  assert {
    condition     = scaleway_instance_server.openclaw.type == "DEV1-S"
    error_message = "Instance should still be created with all modules disabled"
  }
}

# --- Pomerium disabled ---

run "pomerium_disabled_no_container" {
  command = plan
  variables {
    enable_pomerium = false
  }
  assert {
    condition     = length(scaleway_container.pomerium) == 0
    error_message = "Pomerium container should not exist when disabled"
  }
}

run "pomerium_disabled_no_registry" {
  command = plan
  variables {
    enable_pomerium = false
  }
  assert {
    condition     = length(scaleway_registry_namespace.pomerium) == 0
    error_message = "Pomerium registry should not exist when disabled"
  }
}

run "pomerium_disabled_direct_access" {
  command = plan
  variables {
    enable_pomerium = false
  }
  assert {
    condition     = output.pomerium_container_url == "disabled"
    error_message = "Pomerium URL should be 'disabled' when module is off"
  }
}

# --- Kill switch disabled ---

run "killswitch_disabled_no_function" {
  command = plan
  variables {
    enable_killswitch = false
  }
  assert {
    condition     = length(scaleway_function.killswitch) == 0
    error_message = "Kill switch function should not exist when disabled"
  }
}

run "killswitch_disabled_no_cron" {
  command = plan
  variables {
    enable_killswitch = false
  }
  assert {
    condition     = length(scaleway_function_cron.killswitch) == 0
    error_message = "Kill switch cron should not exist when disabled"
  }
}

# --- Monitoring disabled ---

run "monitoring_disabled_no_log_source" {
  command = plan
  variables {
    enable_monitoring = false
  }
  assert {
    condition     = length(scaleway_cockpit_source.logs) == 0
    error_message = "Cockpit log source should not exist when monitoring disabled"
  }
}

run "monitoring_disabled_no_alloy_token" {
  command = plan
  variables {
    enable_monitoring = false
  }
  assert {
    condition     = length(scaleway_cockpit_token.alloy) == 0
    error_message = "Cockpit Alloy token should not exist when monitoring disabled"
  }
}

# --- Backup disabled ---

run "backup_disabled_no_bucket" {
  command = plan
  variables {
    enable_backup = false
  }
  assert {
    condition     = length(scaleway_object_bucket.backup) == 0
    error_message = "Backup bucket should not exist when backup disabled"
  }
}
