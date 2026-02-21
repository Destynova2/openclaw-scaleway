output "record_ids" {
  description = "IDs des records DNS crees"
  value       = { for k, v in scaleway_domain_record.this : k => v.id }
}

output "records" {
  description = "Details des records DNS crees (name, type, ttl)"
  value = { for k, v in scaleway_domain_record.this : k => {
    name = v.name
    type = v.type
    ttl  = v.ttl
  } }
}
