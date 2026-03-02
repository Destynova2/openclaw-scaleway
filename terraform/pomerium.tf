# --- Secrets Pomerium (generes automatiquement) ---

resource "random_bytes" "pomerium_cookie_secret" {
  count  = var.enable_pomerium ? 1 : 0
  length = 32
}

resource "random_bytes" "pomerium_shared_secret" {
  count  = var.enable_pomerium ? 1 : 0
  length = 32
}

# --- Routes Pomerium (auto-generees depuis l'IP privee de l'instance) ---

locals {
  # Filtrer l'IPv4 parmi les private_ips (l'ordre IPv4/IPv6 n'est pas garanti)
  instance_private_ipv4 = try(
    [for ip in scaleway_instance_server.openclaw.private_ips : ip.address if can(regex("^\\d+\\.\\d+\\.\\d+\\.\\d+$", ip.address))][0],
    "10.0.0.1"
  )

  pomerium_routes = var.enable_pomerium ? base64encode(yamlencode([{
    from             = "https://app.${var.domain_name}"
    to               = "http://${local.instance_private_ipv4}:3000"
    allowed_users    = [var.admin_email]
    allow_websockets = true
    timeout          = "60s"
  }])) : ""
}

resource "scaleway_container_namespace" "pomerium" {
  count       = var.enable_pomerium ? 1 : 0
  provider    = scaleway.project
  name        = "pomerium"
  description = "Identity-aware proxy pour OpenClaw"
  tags        = local.default_tags
  # VPC integration is now enabled by default on all namespaces
}

resource "scaleway_registry_namespace" "pomerium" {
  count     = var.enable_pomerium ? 1 : 0
  provider  = scaleway.project
  name      = "pomerium"
  is_public = false
}

# Built automatically by .github/workflows/opentofu.yml (build matrix). Manual push fallback:
#   docker pull pomerium/pomerium:v0.32.0
#   docker tag pomerium/pomerium:v0.32.0 rg.fr-par.scw.cloud/<ns>/pomerium:v0.32.0
#   docker push rg.fr-par.scw.cloud/<ns>/pomerium:v0.32.0
resource "scaleway_container" "pomerium" {
  count          = var.enable_pomerium ? 1 : 0
  provider       = scaleway.project
  name           = "pomerium-proxy"
  namespace_id   = scaleway_container_namespace.pomerium[0].id
  registry_image = "${scaleway_registry_namespace.pomerium[0].endpoint}/pomerium:${var.pomerium_version}"
  port           = 8080
  cpu_limit      = 140
  memory_limit   = 256
  min_scale      = 1
  max_scale      = 2
  deploy         = true

  environment_variables = {
    ADDRESS                  = ":8080"
    AUTOCERT                 = "false"
    IDP_PROVIDER             = "github"
    LOG_LEVEL                = "warn"
    INSECURE_SERVER          = "true"
    AUTHENTICATE_SERVICE_URL = "https://auth.${var.domain_name}"
    POLICY                   = local.pomerium_routes
    # Hash du Containerfile — force le redeploy quand l'image change (meme tag)
    _IMAGE_HASH = filesha256("${path.module}/../containers/Containerfile.pomerium")
  }

  secret_environment_variables = {
    IDP_CLIENT_ID     = var.pomerium_idp_client_id
    IDP_CLIENT_SECRET = var.pomerium_idp_client_secret
    COOKIE_SECRET     = random_bytes.pomerium_cookie_secret[0].base64
    SHARED_SECRET     = random_bytes.pomerium_shared_secret[0].base64
  }

  private_network_id = scaleway_vpc_private_network.openclaw.id
}
