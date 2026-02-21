terraform {
  required_providers {
    ovh = {
      source  = "ovh/ovh"
      version = "~> 2.11"
    }
  }
}

resource "ovh_domain_zone_record" "this" {
  for_each  = var.records
  zone      = var.zone
  subdomain = each.value.name
  fieldtype = each.value.type
  target    = each.value.data
  ttl       = each.value.ttl
}
