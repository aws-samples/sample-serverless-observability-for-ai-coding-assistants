# -----------------------------------------------------------------------------
# VPC Module Variables
# Requirements: 9.1, 9.9
# -----------------------------------------------------------------------------

variable "vpc_cidr" {
  description = "CIDR block for the VPC"
  type        = string
  default     = "10.0.0.0/16"
}

variable "environment" {
  description = "Deployment environment (e.g., dev, staging, prod)"
  type        = string
}

variable "project_name" {
  description = "Project name used for resource naming and tagging"
  type        = string
  default     = "claude-code-telemetry"
}

variable "availability_zones" {
  description = "List of availability zones for multi-AZ deployment"
  type        = list(string)
  default     = ["us-east-1a", "us-east-1b"]
}

variable "tags" {
  description = "Default tags applied to all resources"
  type        = map(string)
  default     = {}
}

# --- Security Group Variables (task 2.3) ---

variable "corporate_cidr_blocks" {
  description = "List of corporate network / VPN CIDR blocks allowed to access Grafana"
  type        = list(string)
  default     = []
}
