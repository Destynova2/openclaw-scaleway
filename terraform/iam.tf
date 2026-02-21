# --- Clef SSH generee (Ed25519) ---

resource "tls_private_key" "admin" {
  algorithm = "ED25519"

  lifecycle {
    prevent_destroy = true
  }
}

resource "scaleway_iam_ssh_key" "admin" {
  name       = "openclaw-admin"
  public_key = tls_private_key.admin.public_key_openssh
  project_id = local.project_id
}

# --- OpenClaw Agent IAM (moindre privilege — GenAI uniquement) ---

module "iam_openclaw" {
  source      = "./modules/iam-service-account"
  name        = "openclaw-agent"
  description = "Application IAM pour OpenClaw - acces Generative APIs uniquement"
  project_id  = local.project_id
  project_rules = [{
    project_ids          = [local.project_id]
    permission_set_names = ["GenerativeApisFullAccess", "ContainerRegistryReadOnly"]
  }]
}

# --- CI/CD IAM (project-scoped, replaces org-admin key after first deploy) ---

module "iam_cicd" {
  source      = "./modules/iam-service-account"
  name        = "openclaw-cicd"
  description = "Application IAM dediee au CI/CD - deploiement infra projet"
  project_id  = local.project_id
  project_rules = concat(
    [{
      project_ids = [local.project_id]
      permission_set_names = [
        "InstancesFullAccess",
        "BlockStorageFullAccess",
        "VPCFullAccess",
        "PrivateNetworksFullAccess",
        "ContainerRegistryFullAccess",
        "ContainersFullAccess",
        "FunctionsFullAccess",
        "ObjectStorageFullAccess",
        "ObservabilityFullAccess",
        "SSHKeysFullAccess",
        "TransactionalEmailFullAccess",
      ]
    }],
    var.state_project_id != "" ? [{
      project_ids          = [var.state_project_id]
      permission_set_names = ["ObjectStorageFullAccess"]
    }] : []
  )
  org_rules = [{
    organization_id      = local.org_id
    permission_set_names = ["IAMManager", "ProjectManager"]
  }]
  extra_api_keys = var.state_project_id != "" ? {
    state = {
      description        = "Cle API CI/CD pour acces S3 state (projet bootstrap)"
      default_project_id = var.state_project_id
    }
  } : {}
}

# --- Kill switch IAM (moindre privilege — poweroff + billing + emails) ---

module "iam_killswitch" {
  count       = var.enable_killswitch ? 1 : 0
  source      = "./modules/iam-service-account"
  name        = "openclaw-killswitch"
  description = "Application IAM dediee au kill switch budgetaire"
  project_id  = local.project_id
  tags        = local.default_tags
  project_rules = [{
    project_ids          = [local.project_id]
    permission_set_names = ["InstancesFullAccess", "TransactionalEmailFullAccess"]
  }]
  org_rules = [{
    organization_id      = scaleway_account_project.openclaw.organization_id
    permission_set_names = ["BillingReadOnly"]
  }]
}
