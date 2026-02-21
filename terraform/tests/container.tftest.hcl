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

run "pomerium_memory_minimum_256" {
  command = plan
  assert {
    condition     = scaleway_container.pomerium[0].memory_limit >= 256
    error_message = "Pomerium container needs minimum 256 Mo for Envoy"
  }
}

run "pomerium_port_8080" {
  command = plan
  assert {
    condition     = scaleway_container.pomerium[0].port == 8080
    error_message = "Pomerium should listen on port 8080 (HTTP behind TLS edge)"
  }
}

run "pomerium_always_on" {
  command = plan
  assert {
    condition     = scaleway_container.pomerium[0].min_scale == 1
    error_message = "Pomerium should be always-on (min_scale = 1)"
  }
}

run "pomerium_registry_private" {
  command = plan
  assert {
    condition     = scaleway_registry_namespace.pomerium[0].is_public == false
    error_message = "Pomerium registry should be private"
  }
}

run "pomerium_insecure_server" {
  command = plan
  assert {
    condition     = scaleway_container.pomerium[0].environment_variables["INSECURE_SERVER"] == "true"
    error_message = "Pomerium should have INSECURE_SERVER=true (TLS at Scaleway edge)"
  }
}

run "pomerium_address" {
  command = plan
  assert {
    condition     = scaleway_container.pomerium[0].environment_variables["ADDRESS"] == ":8080"
    error_message = "Pomerium ADDRESS should be :8080"
  }
}

run "openclaw_registry_private" {
  command = plan
  assert {
    condition     = scaleway_registry_namespace.openclaw.is_public == false
    error_message = "OpenClaw registry should be private"
  }
}
