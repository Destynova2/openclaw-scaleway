# -----------------------------------------------------------------------
# Bootstrap — one-time setup for S3 state bucket and encryption passphrase.
#
# State local uniquement — NE JAMAIS migrer vers le backend S3.
# Ce module cree le bucket S3 et la passphrase utilises par le module principal.
# Avec -var-file=../terraform.tfvars, configure aussi les GitHub Secrets pour le CI/CD.
#
# Run once: cd terraform/bootstrap && tofu init && tofu apply -var-file=../terraform.tfvars
# See CLAUDE.md for full bootstrap sequence.
# -----------------------------------------------------------------------
terraform {
  required_version = ">= 1.8"
  required_providers {
    scaleway = {
      source  = "scaleway/scaleway"
      version = "~> 2.69"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
    github = {
      source  = "integrations/github"
      version = "~> 6.0"
    }
  }
}

# --- Credentials Scaleway (requis) ---

variable "scw_access_key" {
  description = "Scaleway Access Key (SCW...)"
  type        = string
  sensitive   = true
}

variable "scw_secret_key" {
  description = "Scaleway Secret Key (UUID)"
  type        = string
  sensitive   = true
}

# --- Variables pour les GitHub Secrets ---
# Chargees via -var-file=../terraform.tfvars

variable "scw_organization_id" {
  description = "ID de l'organisation Scaleway"
  type        = string
  sensitive   = true
  default     = ""
}

variable "admin_ip_cidr" {
  description = "IP admin pour SSH (format CIDR)"
  type        = string
  default     = ""
}

variable "admin_email" {
  description = "Email de l'administrateur"
  type        = string
  default     = ""
}

variable "domain_name" {
  description = "Nom de domaine (ex: example.com)"
  type        = string
  default     = ""
}

variable "pomerium_idp_client_id" {
  description = "Client ID de l'IdP (GitHub OAuth App)"
  type        = string
  sensitive   = true
  default     = ""
}

variable "pomerium_idp_client_secret" {
  description = "Client Secret de l'IdP"
  type        = string
  sensitive   = true
  default     = ""
}

variable "openclaw_version" {
  description = "Version d'OpenClaw (ex: 1.2.3)"
  type        = string
  default     = ""
}

variable "github_token" {
  description = "GitHub PAT (scope: repo) pour configurer les Actions Secrets"
  type        = string
  sensitive   = true
  default     = ""
}

variable "github_owner" {
  description = "GitHub owner (user ou org)"
  type        = string
  default     = ""
}

variable "github_repository" {
  description = "Nom du repository GitHub (ex: _fmj)"
  type        = string
  default     = ""
}

variable "state_project_id" {
  description = "ID du projet Scaleway contenant le bucket S3 de state"
  type        = string
  default     = ""
}

variable "brave_search_api_key" {
  description = "Cle API Brave Search"
  type        = string
  sensitive   = true
  default     = ""
}

variable "telegram_bot_token" {
  description = "Token du bot Telegram"
  type        = string
  sensitive   = true
  default     = ""
}

variable "telegram_chat_id" {
  description = "Chat ID Telegram pour les alertes"
  type        = string
  default     = ""
}

variable "github_agent_token" {
  description = "Fine-grained PAT GitHub pour l'agent"
  type        = string
  sensitive   = true
  default     = ""
}

# --- Variables ignorees par bootstrap (evite les warnings -var-file) ---

variable "encryption_passphrase" {
  description = "Ignoree par bootstrap (la vraie vient de random_password)"
  type        = string
  sensitive   = true
  default     = ""
}

variable "domain_owner_contact" {
  description = "Ignoree par bootstrap"
  type        = any
  default     = null
}

variable "chrome_headless_version" {
  description = "Ignoree par bootstrap"
  type        = string
  default     = "stable"
}

variable "pomerium_version" {
  description = "Ignoree par bootstrap"
  type        = string
  default     = "v0.32.0"
}

variable "killswitch_budget_eur" {
  description = "Ignoree par bootstrap"
  type        = number
  default     = 15
}

variable "enable_pomerium" {
  description = "Ignoree par bootstrap"
  type        = bool
  default     = true
}

variable "enable_killswitch" {
  description = "Ignoree par bootstrap"
  type        = bool
  default     = true
}

variable "enable_monitoring" {
  description = "Ignoree par bootstrap"
  type        = bool
  default     = true
}

variable "enable_backup" {
  description = "Ignoree par bootstrap"
  type        = bool
  default     = true
}

# --- State bucket ---
variable "state_bucket_name" {
  description = "Nom du bucket S3 pour le state OpenTofu (globalement unique sur Scaleway)"
  type        = string
  default     = "openclaw-terraform-state"
}

# --- Provider ---

provider "scaleway" {
  access_key = var.scw_access_key
  secret_key = var.scw_secret_key
  region     = "fr-par"
  zone       = "fr-par-1"
}

# --- Bucket S3 ---

resource "scaleway_object_bucket" "terraform_state" {
  name   = var.state_bucket_name
  region = "fr-par"

  versioning {
    enabled = true
  }

  tags = {
    managed-by = "opentofu-bootstrap"
  }

  lifecycle {
    prevent_destroy = true
  }
}

# --- Passphrase de chiffrement ---

resource "random_password" "encryption_passphrase" {
  length  = 32
  special = false
}

# --- GitHub Secrets (optionnel, conditionne par github_token) ---
# Utilise la cle admin temporairement. Le premier tofu apply via CI
# cree les IAM keys dediees et met a jour les secrets via github_actions_secret.

provider "github" {
  token = var.github_token != "" ? var.github_token : null
  owner = var.github_owner != "" ? var.github_owner : null
}

locals {
  manage_github = nonsensitive(var.github_token != "") && var.github_repository != "" && var.github_owner != ""

  # Bootstrap pushes all possible secrets (superset); main github.tf conditionally includes Pomerium secrets.
  github_secret_names = toset([
    "SCW_ACCESS_KEY",
    "SCW_SECRET_KEY",
    "SCW_STATE_ACCESS_KEY",
    "SCW_STATE_SECRET_KEY",
    "SCW_ORGANIZATION_ID",
    "TF_VAR_admin_ip_cidr",
    "TF_VAR_admin_email",
    "TF_VAR_domain_name",
    "TF_VAR_pomerium_idp_client_id",
    "TF_VAR_pomerium_idp_client_secret",
    "TF_VAR_openclaw_version",
    "TF_VAR_encryption_passphrase",
    "TF_VAR_state_project_id",
    "TF_VAR_github_token",
    "TF_VAR_github_repository",
    "TF_VAR_github_owner",
    "SCW_REGISTRY_ENDPOINT",
    "SCW_POMERIUM_REGISTRY_ENDPOINT",
    "TF_VAR_brave_search_api_key",
    "TF_VAR_telegram_bot_token",
    "TF_VAR_telegram_chat_id",
    "TF_VAR_github_agent_token",
    "RENOVATE_TOKEN",
    "SCW_STATE_BUCKET",
  ])

  # Cle admin temporaire — remplacee par cle CI IAM au premier tofu apply
  github_secret_values = {
    SCW_ACCESS_KEY                    = var.scw_access_key
    SCW_SECRET_KEY                    = var.scw_secret_key
    SCW_STATE_ACCESS_KEY              = var.scw_access_key
    SCW_STATE_SECRET_KEY              = var.scw_secret_key
    SCW_ORGANIZATION_ID               = var.scw_organization_id
    TF_VAR_admin_ip_cidr              = var.admin_ip_cidr
    TF_VAR_admin_email                = var.admin_email
    TF_VAR_domain_name                = var.domain_name
    TF_VAR_pomerium_idp_client_id     = var.pomerium_idp_client_id
    TF_VAR_pomerium_idp_client_secret = var.pomerium_idp_client_secret
    TF_VAR_openclaw_version           = var.openclaw_version
    TF_VAR_encryption_passphrase      = random_password.encryption_passphrase.result
    TF_VAR_state_project_id           = var.state_project_id
    TF_VAR_github_token               = var.github_token
    TF_VAR_github_repository          = var.github_repository
    TF_VAR_github_owner               = var.github_owner
    SCW_REGISTRY_ENDPOINT             = ""
    SCW_POMERIUM_REGISTRY_ENDPOINT    = ""
    TF_VAR_brave_search_api_key       = var.brave_search_api_key
    TF_VAR_telegram_bot_token         = var.telegram_bot_token
    TF_VAR_telegram_chat_id           = var.telegram_chat_id
    TF_VAR_github_agent_token         = var.github_agent_token
    RENOVATE_TOKEN                    = var.github_token
    SCW_STATE_BUCKET                  = var.state_bucket_name
  }
}

resource "github_actions_secret" "this" {
  for_each        = local.manage_github ? local.github_secret_names : toset([])
  repository      = var.github_repository
  secret_name     = each.value
  plaintext_value = local.github_secret_values[each.value]
}

# --- Passphrase auto-injectee dans le module principal ---
# encryption.auto.tfvars est charge automatiquement par OpenTofu (pas de copie manuelle)

resource "terraform_data" "encryption_tfvars" {
  triggers_replace = [random_password.encryption_passphrase.result]

  provisioner "local-exec" {
    command = "printf 'encryption_passphrase = \"%s\"\\n' \"$PASSPHRASE\" > ${path.module}/../encryption.auto.tfvars"
    environment = {
      PASSPHRASE = random_password.encryption_passphrase.result
    }
  }
}

# --- Outputs ---

output "bucket_name" {
  description = "Nom du bucket S3 pour le backend OpenTofu"
  value       = scaleway_object_bucket.terraform_state.name
}

output "encryption_passphrase" {
  description = "Passphrase PBKDF2 pour le chiffrement du state (a sauvegarder)"
  value       = random_password.encryption_passphrase.result
  sensitive   = true
}
