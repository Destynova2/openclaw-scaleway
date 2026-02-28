# dns-scaleway — Creates DNS records via Scaleway Domains.
# Interface-compatible with dns-ovh for registrar portability.
# Called from: dns.tf. See also: ../dns-ovh/

terraform {
  required_providers {
    scaleway = {
      source = "scaleway/scaleway"
    }
  }
}

resource "scaleway_domain_record" "this" {
  for_each = var.records
  dns_zone = var.zone
  name     = each.value.name
  type     = each.value.type
  data     = each.value.data
  ttl      = each.value.ttl
}
