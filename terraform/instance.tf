resource "random_password" "gateway_token" {
  length  = 32
  special = false

}

locals {
  cloud_init_content = templatefile("${path.module}/cloud-init.yaml.tftpl", {
    scw_api_key             = module.iam_openclaw.secret_key
    scw_project_id          = local.project_id
    domain_name             = var.domain_name
    admin_email             = var.admin_email
    registry_endpoint       = scaleway_registry_namespace.openclaw.endpoint
    registry_auth_b64       = base64encode("nologin:${module.iam_openclaw.secret_key}")
    brave_search_api_key    = var.brave_search_api_key
    telegram_bot_token      = var.telegram_bot_token
    telegram_chat_id        = var.telegram_chat_id
    github_agent_token      = var.github_agent_token
    chrome_headless_version = var.chrome_headless_version
    gateway_token           = random_password.gateway_token.result
    blocked_tokens = join(",", compact([
      module.iam_openclaw.secret_key,
      random_password.gateway_token.result,
      var.brave_search_api_key,
      var.enable_pomerium ? var.pomerium_idp_client_secret : "",
      var.enable_monitoring ? scaleway_cockpit_token.alloy[0].secret_key : "",
    ]))
    backup_bucket         = var.enable_backup ? scaleway_object_bucket.backup[0].name : ""
    backup_password       = var.enable_backup ? random_password.backup[0].result : ""
    backup_access_key     = var.enable_backup ? module.iam_backup[0].access_key : ""
    backup_secret_key     = var.enable_backup ? module.iam_backup[0].secret_key : ""
    cockpit_logs_push_url = var.enable_monitoring ? scaleway_cockpit_source.logs[0].push_url : ""
    cockpit_token         = var.enable_monitoring ? scaleway_cockpit_token.alloy[0].secret_key : ""
  })
}

resource "scaleway_instance_ip" "openclaw" {
  provider = scaleway.project
  tags     = local.default_tags
}

resource "scaleway_instance_server" "openclaw" {
  provider = scaleway.project
  name     = "openclaw-agent"
  type     = "DEV1-S"
  image    = "ubuntu_noble"
  ip_id    = scaleway_instance_ip.openclaw.id

  security_group_id = scaleway_instance_security_group.openclaw.id

  root_volume {
    size_in_gb = 20
  }

  tags = concat(local.default_tags, ["production"])

  # Rattachement au Private Network (bloc imbrique avec pn_id)
  private_network {
    pn_id = scaleway_vpc_private_network.openclaw.id
  }

  user_data = {
    cloud-init = local.cloud_init_content
  }
}
