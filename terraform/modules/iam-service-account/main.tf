terraform {
  required_providers {
    scaleway = {
      source = "scaleway/scaleway"
    }
  }
}

resource "scaleway_iam_application" "this" {
  name        = var.name
  description = var.description
  tags        = var.tags
}

resource "scaleway_iam_api_key" "primary" {
  application_id     = scaleway_iam_application.this.id
  description        = "Cle API primaire pour ${var.name}"
  default_project_id = var.project_id
}

resource "scaleway_iam_api_key" "extra" {
  for_each           = var.extra_api_keys
  application_id     = scaleway_iam_application.this.id
  description        = each.value.description
  default_project_id = each.value.default_project_id
}

resource "scaleway_iam_policy" "this" {
  name           = var.name
  application_id = scaleway_iam_application.this.id

  dynamic "rule" {
    for_each = var.project_rules
    content {
      project_ids          = rule.value.project_ids
      permission_set_names = rule.value.permission_set_names
    }
  }

  dynamic "rule" {
    for_each = var.org_rules
    content {
      organization_id      = rule.value.organization_id
      permission_set_names = rule.value.permission_set_names
    }
  }
}
