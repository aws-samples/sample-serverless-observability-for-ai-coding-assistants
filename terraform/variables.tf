# -----------------------------------------------------------------------------
# Root-Level Variables — Claude Code Telemetry Platform
# -----------------------------------------------------------------------------

variable "aws_region" {
  description = "AWS region for all resources"
  type        = string
  default     = "us-east-1"
}

variable "environment" {
  description = "Deployment environment (e.g., dev, staging, prod)"
  type        = string

  validation {
    condition     = contains(["dev", "staging", "prod"], var.environment)
    error_message = "Environment must be one of: dev, staging, prod."
  }
}

variable "project_name" {
  description = "Project name used for resource naming and tagging"
  type        = string
  default     = "claude-code-telemetry"
}

variable "corporate_cidr_blocks" {
  description = "List of corporate network CIDR blocks allowed to access Grafana dashboards"
  type        = list(string)
}

variable "tags" {
  description = "Default tags applied to all resources"
  type        = map(string)
  default = {
    Project   = "claude-code-telemetry"
    ManagedBy = "terraform"
  }
}

variable "acm_certificate_arn" {
  description = "ARN of the ACM certificate for the ALB HTTPS listener. Leave empty to use self-signed cert."
  type        = string
  default     = ""
}

variable "collector_image" {
  description = "Docker image URI for the OTel Collector container. Leave empty to use the auto-created ECR repository."
  type        = string
  default     = ""
}

variable "telemetry_api_key" {
  description = "Bearer token for authenticating OTLP clients"
  type        = string
  sensitive   = true
}

variable "grafana_auth_provider" {
  description = "Authentication provider for Grafana (SAML or AWS_SSO). Use AWS_SSO only if IAM Identity Center is enabled in the account."
  type        = string
  default     = "SAML"
}

variable "grafana_workspace_name" {
  description = "Override the Grafana workspace name. Leave empty for default."
  type        = string
  default     = ""
}
