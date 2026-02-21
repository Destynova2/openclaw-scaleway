resource "scaleway_registry_namespace" "openclaw" {
  provider  = scaleway.project
  name      = "openclaw"
  is_public = false
}
