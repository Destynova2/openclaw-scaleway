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

run "valid_variables" {
  command = plan
  assert {
    condition     = scaleway_account_project.openclaw.name == "openclaw-production"
    error_message = "Valid variables should produce a valid plan"
  }
}

run "invalid_admin_ip_cidr" {
  command = plan
  variables {
    admin_ip_cidr = "not-a-cidr"
  }
  expect_failures = [var.admin_ip_cidr]
}

run "encryption_passphrase_too_short" {
  command = plan
  variables {
    encryption_passphrase = "short"
  }
  expect_failures = [var.encryption_passphrase]
}

run "invalid_admin_email" {
  command = plan
  variables {
    admin_email = "not-an-email"
  }
  expect_failures = [var.admin_email]
}

run "invalid_openclaw_version_latest" {
  command = plan
  variables {
    openclaw_version = "latest"
  }
  expect_failures = [var.openclaw_version]
}

run "invalid_openclaw_version_no_semver" {
  command = plan
  variables {
    openclaw_version = "v1.2.3"
  }
  expect_failures = [var.openclaw_version]
}

run "killswitch_budget_below_minimum" {
  command = plan
  variables {
    killswitch_budget_eur = 10
  }
  expect_failures = [var.killswitch_budget_eur]
}

run "killswitch_budget_custom" {
  command = plan
  variables {
    killswitch_budget_eur = 20
  }
  assert {
    condition     = scaleway_function.killswitch[0].environment_variables["BUDGET_THRESHOLD_EUR"] == "20"
    error_message = "Kill switch should use custom budget threshold"
  }
  assert {
    condition     = scaleway_function.killswitch[0].environment_variables["ALERT_THRESHOLD_EUR"] == "17"
    error_message = "Alert threshold should be budget - 3"
  }
}
