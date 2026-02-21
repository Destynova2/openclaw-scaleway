# --- GitHub Actions Secrets (optionnel, conditionne par github_token) ---
# Les cles sont non-sensibles (for_each interdit les valeurs sensibles).
# Les valeurs sont sensibles et resolues via lookup.

locals {
  manage_github = nonsensitive(var.github_token != "") && var.github_repository != ""

  # Secrets de base (toujours presents)
  github_secret_names_base = toset([
    "SCW_ACCESS_KEY",
    "SCW_SECRET_KEY",
    "SCW_STATE_ACCESS_KEY",
    "SCW_STATE_SECRET_KEY",
    "SCW_ORGANIZATION_ID",
    "TF_VAR_admin_ip_cidr",
    "TF_VAR_admin_email",
    "TF_VAR_domain_name",
    "TF_VAR_openclaw_version",
    "TF_VAR_encryption_passphrase",
    "TF_VAR_github_token",
    "TF_VAR_github_repository",
    "TF_VAR_github_owner",
    "TF_VAR_state_project_id",
    "SCW_REGISTRY_ENDPOINT",
    "TF_VAR_brave_search_api_key",
    "TF_VAR_telegram_bot_token",
    "TF_VAR_telegram_chat_id",
    "TF_VAR_github_agent_token",
    "RENOVATE_TOKEN",
  ])

  # Secrets Pomerium (conditionnels)
  github_secret_names_pomerium = var.enable_pomerium ? toset([
    "TF_VAR_pomerium_idp_client_id",
    "TF_VAR_pomerium_idp_client_secret",
    "SCW_POMERIUM_REGISTRY_ENDPOINT",
  ]) : toset([])

  github_secret_names = setunion(local.github_secret_names_base, local.github_secret_names_pomerium)

  github_secret_values = merge(
    {
      SCW_ACCESS_KEY               = module.iam_cicd.access_key
      SCW_SECRET_KEY               = module.iam_cicd.secret_key
      SCW_STATE_ACCESS_KEY         = try(module.iam_cicd.extra_keys["state"].access_key, module.iam_cicd.access_key)
      SCW_STATE_SECRET_KEY         = try(module.iam_cicd.extra_keys["state"].secret_key, module.iam_cicd.secret_key)
      SCW_ORGANIZATION_ID          = local.org_id
      TF_VAR_admin_ip_cidr         = var.admin_ip_cidr
      TF_VAR_admin_email           = var.admin_email
      TF_VAR_domain_name           = var.domain_name
      TF_VAR_openclaw_version      = var.openclaw_version
      TF_VAR_encryption_passphrase = var.encryption_passphrase
      TF_VAR_github_token          = var.github_token
      TF_VAR_github_repository     = var.github_repository
      TF_VAR_github_owner          = var.github_owner
      TF_VAR_state_project_id      = var.state_project_id
      SCW_REGISTRY_ENDPOINT        = scaleway_registry_namespace.openclaw.endpoint
      TF_VAR_brave_search_api_key  = var.brave_search_api_key
      TF_VAR_telegram_bot_token    = var.telegram_bot_token
      TF_VAR_telegram_chat_id      = var.telegram_chat_id
      TF_VAR_github_agent_token    = var.github_agent_token
      RENOVATE_TOKEN               = var.github_token
    },
    var.enable_pomerium ? {
      TF_VAR_pomerium_idp_client_id     = var.pomerium_idp_client_id
      TF_VAR_pomerium_idp_client_secret = var.pomerium_idp_client_secret
      SCW_POMERIUM_REGISTRY_ENDPOINT    = scaleway_registry_namespace.pomerium[0].endpoint
    } : {}
  )
}

resource "github_actions_secret" "this" {
  for_each        = local.manage_github ? local.github_secret_names : toset([])
  repository      = var.github_repository
  secret_name     = each.value
  plaintext_value = local.github_secret_values[each.value]
}
