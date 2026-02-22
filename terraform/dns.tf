# --- DNS records (module interchangeable : dns-scaleway ou dns-ovh) ---

locals {
  # Records de base (toujours presents)
  dns_base_records = {
    webhooks_a = { name = "webhooks", type = "A", data = scaleway_instance_ip.openclaw.address }
    tem_spf    = { name = "", type = "TXT", data = "v=spf1 include:_spf.tem.scaleway.com -all", ttl = 3600 }
    tem_dkim   = { name = "${local.project_id}._domainkey", type = "TXT", data = scaleway_tem_domain.openclaw.dkim_config, ttl = 3600 }
    tem_dmarc  = { name = "_dmarc", type = "TXT", data = "v=DMARC1; p=none", ttl = 3600 }
  }

  # Records Pomerium (CNAMEs pour app et auth)
  dns_pomerium_records = var.enable_pomerium ? {
    app_cname  = { name = "app", type = "CNAME", data = "${scaleway_container.pomerium[0].domain_name}." }
    auth_cname = { name = "auth", type = "CNAME", data = "${scaleway_container.pomerium[0].domain_name}." }
  } : {}
}

module "dns" {
  source  = "./modules/dns-scaleway"
  zone    = var.domain_name
  records = merge(local.dns_base_records, local.dns_pomerium_records)

  # Note : la zone DNS existe des l'enregistrement du domaine.
  # Pas de depends_on sur domain_registration pour eviter de bloquer
  # les records quand le domaine est hors state (import impossible).
}

# Custom domains sur le Serverless Container — declenche Let's Encrypt auto
resource "scaleway_container_domain" "pomerium_app" {
  count        = var.enable_pomerium ? 1 : 0
  provider     = scaleway.project
  container_id = scaleway_container.pomerium[0].id
  hostname     = "app.${var.domain_name}"

  depends_on = [module.dns]
}

resource "scaleway_container_domain" "pomerium_auth" {
  count        = var.enable_pomerium ? 1 : 0
  provider     = scaleway.project
  container_id = scaleway_container.pomerium[0].id
  hostname     = "auth.${var.domain_name}"

  depends_on = [module.dns]
}
