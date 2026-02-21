output "record_ids" {
  description = "IDs des records DNS crees"
  value       = { for k, v in ovh_domain_zone_record.this : k => v.id }
}
