# Grafana Module — Amazon Managed Grafana
# Manages the Grafana workspace, data source configuration, and dashboard provisioning
# Requirements: 5.1-5.7, 6.1-6.6, 7.13-7.15, 7.19-7.20

data "aws_region" "current" {}

# -----------------------------------------------------------------------------
# Amazon Managed Grafana Workspace
# Authentication: AWS SSO (IAM Identity Center) integrated with Cognito
# Session timeout: 8 hours (Requirement 7.19)
# -----------------------------------------------------------------------------
resource "aws_grafana_workspace" "main" {
  name                     = var.grafana_workspace_name != "" ? var.grafana_workspace_name : "${var.project_name}-${var.environment}"
  description              = "Claude Code Telemetry dashboards for ${var.environment}"
  account_access_type      = "CURRENT_ACCOUNT"
  authentication_providers = [var.grafana_auth_provider]
  permission_type          = "SERVICE_MANAGED"
  role_arn                 = var.grafana_role_arn
  data_sources             = ["CLOUDWATCH", "ATHENA"]

  vpc_configuration {
    subnet_ids         = var.private_subnet_ids
    security_group_ids = [var.sg_grafana_id]
  }

  configuration = jsonencode({
    unifiedAlerting = {
      enabled = true
    }
    plugins = {
      pluginAdminEnabled = true
    }
  })

  tags = var.tags
}

# -----------------------------------------------------------------------------
# Grafana Role Association — Admin and Editor roles via SSO
# Requirement 7.14, 7.15: role-based access (admin vs developer)
# -----------------------------------------------------------------------------
# Grafana Role Associations disabled — SAML auth doesn't support SSO group mapping.
# Configure role assignments manually in the Grafana workspace after deployment.
# resource "aws_grafana_role_association" "admin" {
#   role         = "ADMIN"
#   workspace_id = aws_grafana_workspace.main.id
#   group_ids    = []
# }
# resource "aws_grafana_role_association" "viewer" {
#   role         = "VIEWER"
#   workspace_id = aws_grafana_workspace.main.id
#   group_ids    = []
# }
