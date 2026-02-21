resource "scaleway_instance_security_group" "openclaw" {
  provider               = scaleway.project
  name                   = "openclaw-sg"
  inbound_default_policy = "drop"
  # Egress ouvert intentionnel : necessaire pour apt, Docker Hub pulls,
  # Scaleway API (GenAI, registry, DNS) et Let's Encrypt ACME.
  # Le filtrage egress par IP/port n'est pas praticable (endpoints dynamiques).
  outbound_default_policy = "accept"

  # SSH — ouvert (securise par cle Ed25519 + fail2ban)
  inbound_rule {
    action   = "accept"
    port     = 22
    ip_range = var.admin_ip_cidr
    protocol = "TCP"
  }

  # HTTPS entrant (webhooks messaging)
  inbound_rule {
    action   = "accept"
    port     = 443
    ip_range = "0.0.0.0/0"
    protocol = "TCP"
  }

  # HTTP entrant (Let's Encrypt ACME challenge)
  inbound_rule {
    action   = "accept"
    port     = 80
    ip_range = "0.0.0.0/0"
    protocol = "TCP"
  }

  # Port 3000 (web UI OpenClaw) : NON ouvert sur Internet
  # Pomerium y accede via le Private Network (bypass le security group)

  tags = local.default_tags
}
