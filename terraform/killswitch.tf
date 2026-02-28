# -----------------------------------------------------------------------
# Kill switch budgetaire — arret automatique de l'instance si budget depasse
#
# Fonctionnement :
#   - Cron toutes les heures → appel Billing API (conso projet openclaw)
#   - Si conso >= var.killswitch_budget_eur (defaut 15 EUR, min 13) → poweroff instance
#   - Invocation manuelle via HTTP toujours possible (protege par token Bearer ou ?token=)
#
# Alerte email automatique a (budget - 3) EUR, poweroff a budget EUR.
#
# Test manuel :
#   tofu output -raw killswitch_webhook_url | xargs curl
#
# Tests : cd killswitch && python3 -m unittest test_handler
# Desactiver : enable_killswitch = false
# -----------------------------------------------------------------------

data "archive_file" "killswitch" {
  count       = var.enable_killswitch ? 1 : 0
  type        = "zip"
  source_file = "${path.module}/killswitch/handler.py"
  output_path = "${path.module}/killswitch/handler.zip"
}

resource "random_password" "killswitch_token" {
  count   = var.enable_killswitch ? 1 : 0
  length  = 32
  special = false
}

resource "scaleway_function_namespace" "killswitch" {
  count    = var.enable_killswitch ? 1 : 0
  provider = scaleway.project
  name     = "killswitch"
  tags     = local.default_tags
}

resource "scaleway_function" "killswitch" {
  count        = var.enable_killswitch ? 1 : 0
  provider     = scaleway.project
  name         = "budget-killswitch"
  namespace_id = scaleway_function_namespace.killswitch[0].id
  runtime      = "python310"
  handler      = "handler.handler"
  privacy      = "public"
  zip_file     = data.archive_file.killswitch[0].output_path
  zip_hash     = data.archive_file.killswitch[0].output_sha256

  environment_variables = {
    SERVER_ID            = element(split("/", scaleway_instance_server.openclaw.id), 1)
    SCW_DEFAULT_ZONE     = local.zone
    BILLING_PROJECT_ID   = local.project_id
    BUDGET_THRESHOLD_EUR = tostring(var.killswitch_budget_eur)
    ALERT_THRESHOLD_EUR  = tostring(var.killswitch_budget_eur - 3)
    ADMIN_EMAIL          = var.admin_email
    DOMAIN_NAME          = var.domain_name
  }

  secret_environment_variables = {
    KILLSWITCH_TOKEN = random_password.killswitch_token[0].result
    SCW_ACCESS_KEY   = module.iam_killswitch[0].access_key
    SCW_SECRET_KEY   = module.iam_killswitch[0].secret_key
  }
}

resource "scaleway_function_cron" "killswitch" {
  count       = var.enable_killswitch ? 1 : 0
  provider    = scaleway.project
  function_id = scaleway_function.killswitch[0].id
  schedule    = "0 * * * *"
  args        = jsonencode({})
}
