# --- Scaleway ---
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

variable "scw_organization_id" {
  description = "ID de l'organisation Scaleway"
  type        = string
  sensitive   = true
}

variable "admin_ip_cidr" {
  description = "IP admin pour SSH (format CIDR, ex: 203.0.113.42/32)"
  type        = string
  validation {
    condition     = can(cidrhost(var.admin_ip_cidr, 0))
    error_message = "admin_ip_cidr doit etre un CIDR valide (ex: 1.2.3.4/32)"
  }
}

variable "admin_email" {
  description = "Email de l'administrateur (autorise dans Pomerium)"
  type        = string
  validation {
    condition     = can(regex("^[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\\.[a-zA-Z]{2,}$", var.admin_email))
    error_message = "admin_email doit etre une adresse email valide (ex: admin@example.com)"
  }
}

# --- Domaine (Scaleway Domains) ---
variable "domain_name" {
  description = "Nom de domaine enregistre via Scaleway (ex: example.com)"
  type        = string
}

# --- OpenClaw ---
variable "openclaw_version" {
  description = "Version d'OpenClaw a installer (ex: 1.2.3). Epinglee pour la reproductibilite."
  type        = string
  validation {
    condition     = can(regex("^[0-9]+\\.[0-9]+\\.[0-9]+$", var.openclaw_version))
    error_message = "openclaw_version doit etre au format semver (ex: 1.2.3). 'latest' est interdit."
  }
}

# --- Chrome Headless ---
variable "chrome_headless_version" {
  description = "Version de chromedp/headless-shell pour le sidecar browser agent"
  type        = string
  default     = "stable"
}

# --- Pomerium ---
variable "pomerium_version" {
  description = "Version de Pomerium (tag Docker, ex: v0.32.0)"
  type        = string
  default     = "v0.32.0"
}

variable "pomerium_idp_client_id" {
  description = "Client ID de l'IdP (GitHub OAuth App). Required when enable_pomerium = true."
  type        = string
  sensitive   = true
  default     = ""
}

variable "pomerium_idp_client_secret" {
  description = "Client Secret de l'IdP. Required when enable_pomerium = true."
  type        = string
  sensitive   = true
  default     = ""
}

# --- GitHub (gestion automatique des Actions Secrets) ---
variable "github_token" {
  description = "GitHub PAT (scope: repo) pour configurer les Actions Secrets. Laisser vide pour ignorer."
  type        = string
  sensitive   = true
  default     = ""
}

variable "github_repository" {
  description = "Nom du repository GitHub (ex: openclaw). Requis si github_token est fourni."
  type        = string
  default     = ""
}

variable "github_owner" {
  description = "GitHub owner (user ou org). Requis si github_token est fourni."
  type        = string
  default     = ""
}

# --- Brave Search ---
variable "brave_search_api_key" {
  description = "Cle API Brave Search pour le web_search de l'agent"
  type        = string
  sensitive   = true
  default     = ""
}

# --- GitHub Agent (acces repos prives) ---
variable "github_agent_token" {
  description = "Fine-grained PAT GitHub pour l'agent (scope: Contents, PRs, Issues sur les repos prives)."
  type        = string
  sensitive   = true
  default     = ""
}

# --- Telegram ---
variable "telegram_bot_token" {
  description = "Token du bot Telegram (via @BotFather). Laisser vide pour desactiver."
  type        = string
  sensitive   = true
  default     = ""
}

variable "telegram_chat_id" {
  description = "Chat ID Telegram pour les alertes (kill switch, dns-monitor, token-guard)."
  type        = string
  default     = ""
}

# --- State S3 ---
variable "state_project_id" {
  description = "ID du projet Scaleway contenant le bucket S3 de state (cree par le bootstrap). Laisser vide si identique au projet openclaw."
  type        = string
  default     = ""
}

# --- Domaine (Scaleway Domains) ---
variable "domain_owner_contact" {
  description = "Contact WHOIS pour l'enregistrement du domaine. Mettre null pour ignorer l'achat."
  type = object({
    legal_form                  = string # "individual" ou "company"
    firstname                   = string
    lastname                    = string
    email                       = string
    phone_number                = string # format international: +33.612345678
    address_line_1              = string
    zip                         = string
    city                        = string
    country                     = string # code ISO 2 lettres: FR
    company_name                = optional(string, "")
    vat_identification_code     = optional(string, "")
    company_identification_code = optional(string, "")
  })
  sensitive = true
  default   = null
}

# --- Feature toggles (all enabled by default) ---
variable "enable_pomerium" {
  description = "Deploy Pomerium SSO gateway. Set false for direct access via IP."
  type        = bool
  default     = true
}

variable "enable_killswitch" {
  description = "Deploy budget kill switch (hourly cron, auto-poweroff)."
  type        = bool
  default     = true
}

variable "enable_monitoring" {
  description = "Deploy Cockpit external log shipping via Grafana Alloy."
  type        = bool
  default     = true
}

variable "enable_backup" {
  description = "Deploy S3 backup bucket with restic."
  type        = bool
  default     = true
}

# --- Kill switch ---
variable "killswitch_budget_eur" {
  description = "Seuil de poweroff automatique en EUR. Le kill switch eteint l'instance si la conso mensuelle depasse ce montant."
  type        = number
  default     = 15
  validation {
    condition     = var.killswitch_budget_eur >= 13
    error_message = "Le seuil minimum est 13 EUR (cout de base de l'infra)."
  }
}

# --- Chiffrement state ---
variable "encryption_passphrase" {
  description = "Passphrase pour le chiffrement client-side du state et du plan (PBKDF2 + AES-GCM). Minimum 16 caracteres."
  type        = string
  sensitive   = true
  validation {
    condition     = length(var.encryption_passphrase) >= 16
    error_message = "La passphrase de chiffrement doit faire au moins 16 caracteres."
  }
}
