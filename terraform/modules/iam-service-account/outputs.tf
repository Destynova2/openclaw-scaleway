output "application_id" {
  description = "ID de l'application IAM"
  value       = scaleway_iam_application.this.id
}

output "access_key" {
  description = "Access key de la cle API primaire"
  value       = scaleway_iam_api_key.primary.access_key
}

output "secret_key" {
  description = "Secret key de la cle API primaire"
  value       = scaleway_iam_api_key.primary.secret_key
  sensitive   = true
}

output "extra_keys" {
  description = "Cles API supplementaires (access_key + secret_key par nom)"
  value = { for k, v in scaleway_iam_api_key.extra : k => {
    access_key = v.access_key
    secret_key = v.secret_key
  } }
  sensitive = true
}
