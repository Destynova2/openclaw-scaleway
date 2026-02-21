variable "name" {
  description = "Nom de l'application IAM"
  type        = string
}

variable "description" {
  description = "Description de l'application IAM"
  type        = string
  default     = ""
}

variable "project_id" {
  description = "ID du projet Scaleway (default_project_id de la cle API primaire)"
  type        = string
}

variable "tags" {
  description = "Tags a appliquer sur l'application IAM"
  type        = list(string)
  default     = []
}

variable "project_rules" {
  description = "Regles IAM project-scoped (permissions par projet)"
  type = list(object({
    project_ids          = list(string)
    permission_set_names = set(string)
  }))
}

variable "org_rules" {
  description = "Regles IAM org-scoped (permissions globales organisation)"
  type = list(object({
    organization_id      = string
    permission_set_names = set(string)
  }))
  default = []
}

variable "extra_api_keys" {
  description = "Cles API supplementaires (ex: cle S3 state avec un default_project_id different)"
  type = map(object({
    description        = string
    default_project_id = string
  }))
  default = {}
}
