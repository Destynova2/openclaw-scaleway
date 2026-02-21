# Cockpit est active par defaut sur chaque projet Scaleway.
# scaleway_cockpit_grafana_user est DEPRECIE (supprime Jan 2026).
# L'authentification Grafana passe desormais par IAM Scaleway.

data "scaleway_cockpit_grafana" "main" {
  project_id = local.project_id
}

# --- Cockpit : source de logs + token pour Grafana Alloy ---
# Desactiver : enable_monitoring = false (economise ~1 EUR/mois)

resource "scaleway_cockpit_source" "logs" {
  count          = var.enable_monitoring ? 1 : 0
  project_id     = local.project_id
  name           = "openclaw-logs"
  type           = "logs"
  retention_days = 7
}

resource "scaleway_cockpit_token" "alloy" {
  count      = var.enable_monitoring ? 1 : 0
  project_id = local.project_id
  name       = "alloy-push"
  scopes {
    query_metrics       = false
    write_metrics       = false
    query_logs          = false
    write_logs          = true
    query_traces        = false
    write_traces        = false
    setup_alerts        = false
    setup_metrics_rules = false
    setup_logs_rules    = false
  }
}
