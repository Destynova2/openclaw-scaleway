# -----------------------------------------------------------------------
# OpenClaw on Scaleway — main configuration
#
# Creates an isolated Scaleway project and configures providers (Scaleway,
# GitHub, TLS, Random, Archive) for deploying the OpenClaw agent stack.
#
# State: encrypted client-side (PBKDF2 + AES-GCM) in S3 backend.
# See CLAUDE.md for deployment instructions.
# -----------------------------------------------------------------------

terraform {
  required_providers {
    scaleway = {
      source  = "scaleway/scaleway"
      version = "~> 2.69"
    }
    tls = {
      source  = "hashicorp/tls"
      version = "~> 4.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
    github = {
      source  = "integrations/github"
      version = "~> 6.0"
    }
    archive = {
      source  = "hashicorp/archive"
      version = "~> 2.7"
    }
    null = {
      source  = "hashicorp/null"
      version = "~> 3.2"
    }
  }
  required_version = ">= 1.8"

  # Backend S3 — bucket name configured via backend.conf or -backend-config
  # (backend blocks cannot use variables in OpenTofu/Terraform)
  backend "s3" {
    key    = "openclaw/terraform.tfstate"
    region = "fr-par"

    endpoints = {
      s3 = "https://s3.fr-par.scw.cloud"
    }

    skip_credentials_validation = true
    skip_region_validation      = true
    skip_requesting_account_id  = true
    skip_s3_checksum            = true
  }

  encryption {
    key_provider "pbkdf2" "main" {
      passphrase = var.encryption_passphrase
    }

    method "aes_gcm" "main" {
      keys = key_provider.pbkdf2.main
    }

    state {
      method = method.aes_gcm.main
    }

    plan {
      method = method.aes_gcm.main
    }
  }
}

provider "scaleway" {
  access_key      = var.scw_access_key
  secret_key      = var.scw_secret_key
  organization_id = var.scw_organization_id
  zone            = "fr-par-1"
  region          = "fr-par"
}

resource "scaleway_account_project" "openclaw" {
  name        = "openclaw-production"
  description = "Projet isole pour le deploiement OpenClaw"

  lifecycle {
    prevent_destroy = true
  }
}

provider "scaleway" {
  alias           = "project"
  access_key      = var.scw_access_key
  secret_key      = var.scw_secret_key
  organization_id = var.scw_organization_id
  project_id      = local.project_id
  zone            = "fr-par-1"
  region          = "fr-par"
}

provider "github" {
  token = var.github_token != "" ? var.github_token : null
  owner = var.github_owner != "" ? var.github_owner : null
}

locals {
  project_id   = scaleway_account_project.openclaw.id
  org_id       = var.scw_organization_id
  zone         = "fr-par-1"
  region       = "fr-par"
  default_tags = ["openclaw"]
}
