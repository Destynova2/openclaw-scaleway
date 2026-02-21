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

run "vpc_has_openclaw_tag" {
  command = plan
  assert {
    condition     = contains(scaleway_vpc_private_network.openclaw.tags, "openclaw")
    error_message = "VPC should have openclaw tag"
  }
}

run "security_group_drop_by_default" {
  command = plan
  assert {
    condition     = scaleway_instance_security_group.openclaw.inbound_default_policy == "drop"
    error_message = "Security group inbound default policy should be drop"
  }
}

run "ssh_restricted_to_admin_ip" {
  command = plan
  assert {
    condition     = scaleway_instance_security_group.openclaw.inbound_rule[0].port == 22
    error_message = "First inbound rule should be SSH on port 22"
  }
  assert {
    condition     = scaleway_instance_security_group.openclaw.inbound_rule[0].ip_range == "203.0.113.42/32"
    error_message = "SSH should be restricted to admin IP"
  }
}

run "https_open" {
  command = plan
  assert {
    condition     = scaleway_instance_security_group.openclaw.inbound_rule[1].port == 443
    error_message = "Second inbound rule should be HTTPS on port 443"
  }
  assert {
    condition     = scaleway_instance_security_group.openclaw.inbound_rule[1].ip_range == "0.0.0.0/0"
    error_message = "HTTPS should be open to all"
  }
}

run "http_open_for_acme" {
  command = plan
  assert {
    condition     = scaleway_instance_security_group.openclaw.inbound_rule[2].port == 80
    error_message = "Third inbound rule should be HTTP on port 80 for ACME"
  }
}
