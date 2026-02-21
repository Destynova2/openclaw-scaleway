# --- Scaleway Transactional Email (notifications kill switch) ---

resource "scaleway_tem_domain" "openclaw" {
  provider   = scaleway.project
  name       = var.domain_name
  accept_tos = true
}
