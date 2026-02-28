output "record_ids" {
  description = "IDs des records DNS crees"
  value       = { for k, v in ovh_domain_zone_record.this : k => v.id }
}

output "records" {
  description = "Details des records DNS crees (name, type, ttl)"
  value = { for k, v in ovh_domain_zone_record.this : k => {
    name = v.subdomain
    type = v.fieldtype
    ttl  = v.ttl
  } }
}
