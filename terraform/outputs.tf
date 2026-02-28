output "project_id" {
  description = "ID du projet Scaleway"
  value       = local.project_id
}

output "instance_public_ip" {
  description = "IP publique de l'instance OpenClaw"
  value       = scaleway_instance_ip.openclaw.address
}

output "instance_private_ip" {
  description = "IP privee IPv4 de l'instance (Private Network)"
  value       = local.instance_private_ipv4
}

output "pomerium_container_url" {
  description = "URL du container Pomerium (domaine Scaleway)"
  value       = var.enable_pomerium ? "https://${scaleway_container.pomerium[0].domain_name}" : "disabled"
}

output "openclaw_web_ui" {
  description = "URL de la web UI OpenClaw (via Pomerium)"
  value       = var.enable_pomerium ? "https://app.${var.domain_name}" : "http://${scaleway_instance_ip.openclaw.address}:3000"
}

output "webhooks_url" {
  description = "URL pour les webhooks Telegram/WhatsApp"
  value       = "https://webhooks.${var.domain_name}"
}

output "grafana_url" {
  description = "URL du dashboard Grafana (Cockpit) — s'authentifier via IAM Scaleway"
  value       = data.scaleway_cockpit_grafana.main.grafana_url
}

output "openclaw_api_key_access_key" {
  description = "Access key de la cle API IAM OpenClaw (sensitive: credential API)"
  value       = module.iam_openclaw.access_key
  sensitive   = true
}

output "killswitch_function_url" {
  description = "URL de la fonction kill switch (declenchement auto par cron toutes les heures)"
  value       = var.enable_killswitch ? scaleway_function.killswitch[0].domain_name : "disabled"
  sensitive   = true
}

output "killswitch_webhook_url" {
  description = "URL du kill switch avec token (sensitive: contient le token d'auth)"
  value       = var.enable_killswitch ? "https://${scaleway_function.killswitch[0].domain_name}?token=${random_password.killswitch_token[0].result}" : "disabled"
  sensitive   = true
}

output "cicd_access_key" {
  description = "Access key de la cle API CI/CD (project-scoped)"
  value       = module.iam_cicd.access_key
  sensitive   = true
}

output "cicd_secret_key" {
  description = "Secret key de la cle API CI/CD (project-scoped)"
  value       = module.iam_cicd.secret_key
  sensitive   = true
}

output "ssh_private_key" {
  description = "Clef privee SSH Ed25519 — sauvegarder dans ~/.ssh/openclaw"
  value       = tls_private_key.admin.private_key_openssh
  sensitive   = true
}

output "gateway_token" {
  description = "Token d'authentification du gateway OpenClaw (sensitive: credential API)"
  value       = random_password.gateway_token.result
  sensitive   = true
}

output "backup_password" {
  description = "Mot de passe restic pour les backups S3. SAUVEGARDER — irrecuperable sinon."
  value       = var.enable_backup ? random_password.backup[0].result : "disabled"
  sensitive   = true
}

output "backup_repository" {
  description = "URL du repository restic S3"
  value       = var.enable_backup ? "s3:https://s3.fr-par.scw.cloud/${scaleway_object_bucket.backup[0].name}/openclaw" : "disabled"
}
