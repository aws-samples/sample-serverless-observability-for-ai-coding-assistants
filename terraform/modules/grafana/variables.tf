# Grafana Module Variables

variable "project_name" {
  type = string
}

variable "environment" {
  type = string
}

variable "tags" {
  type    = map(string)
  default = {}
}

variable "grafana_role_arn" {
  type = string
}

variable "sg_grafana_id" {
  type = string
}

variable "private_subnet_ids" {
  type = list(string)
}

variable "grafana_auth_provider" {
  description = "Authentication provider for Grafana. Use AWS_SSO if IAM Identity Center is enabled, SAML otherwise."
  type        = string
  default     = "SAML"
}

variable "grafana_workspace_name" {
  description = "Override the Grafana workspace name. Leave empty to use default naming."
  type        = string
  default     = ""
}
