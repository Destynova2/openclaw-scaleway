# -----------------------------------------------------------------------
# Instance — DEV1-S with cloud-init and template rendering pipeline.
#
# Locals pre-render sub-templates from templates/ (kube.yml.tftpl,
# openclaw.json.tftpl, dns-monitor.sh.tftpl) and scripts/ (reconcile-config.py)
# then inject them into cloud-init.yaml.tftpl via indent().
# See reconcile.tf for automatic reboot on content changes.
# -----------------------------------------------------------------------

resource "random_password" "gateway_token" {
  length  = 32
  special = false

}

locals {
  # Templates pre-rendus pour reduire la taille de cloud-init.yaml.tftpl
  kube_yml = templatefile("${path.module}/templates/kube.yml.tftpl", {
    registry_endpoint       = scaleway_registry_namespace.openclaw.endpoint
    scw_api_key             = module.iam_openclaw.secret_key
    scw_project_id          = local.project_id
    github_agent_token      = var.github_agent_token
    chrome_headless_version = var.chrome_headless_version
  })

  grob_toml = templatefile("${path.module}/templates/grob.toml.tftpl", {
    scw_api_key    = module.iam_openclaw.secret_key
    scw_project_id = local.project_id
  })

  openclaw_json = templatefile("${path.module}/templates/openclaw.json.tftpl", {
    scw_api_key          = module.iam_openclaw.secret_key
    scw_project_id       = local.project_id
    brave_search_api_key = var.brave_search_api_key
    domain_name          = var.domain_name
    gateway_token        = random_password.gateway_token.result
    telegram_bot_token   = var.telegram_bot_token
  })

  dns_monitor_sh = templatefile("${path.module}/templates/dns-monitor.sh.tftpl", {
    telegram_bot_token = var.telegram_bot_token
    telegram_chat_id   = var.telegram_chat_id
  })

  reconcile_py = file("${path.module}/scripts/reconcile-config.py")

  cloud_init_content = templatefile("${path.module}/cloud-init.yaml.tftpl", {
    domain_name           = var.domain_name
    registry_auth_b64     = base64encode("nologin:${module.iam_openclaw.secret_key}")
    gateway_token         = random_password.gateway_token.result
    telegram_bot_token    = var.telegram_bot_token
    telegram_chat_id      = var.telegram_chat_id
    backup_bucket         = var.enable_backup ? scaleway_object_bucket.backup[0].name : ""
    backup_password       = var.enable_backup ? random_password.backup[0].result : ""
    backup_access_key     = var.enable_backup ? module.iam_backup[0].access_key : ""
    backup_secret_key     = var.enable_backup ? module.iam_backup[0].secret_key : ""
    cockpit_logs_push_url = var.enable_monitoring ? scaleway_cockpit_source.logs[0].push_url : ""
    cockpit_token         = var.enable_monitoring ? scaleway_cockpit_token.alloy[0].secret_key : ""
    grob_toml             = local.grob_toml
    kube_yml              = local.kube_yml
    openclaw_json         = local.openclaw_json
    dns_monitor_sh        = local.dns_monitor_sh
    reconcile_py          = local.reconcile_py
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
