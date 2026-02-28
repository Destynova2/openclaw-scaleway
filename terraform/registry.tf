# Private container registry for OpenClaw images (Caddy, OpenClaw, CLI, Token Guard, Autopair).
resource "scaleway_registry_namespace" "openclaw" {
  provider  = scaleway.project
  name      = "openclaw"
  is_public = false
}
