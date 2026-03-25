# ALB Module Variables

variable "project_name" {
  description = "Project name used for resource naming"
  type        = string
}

variable "environment" {
  description = "Deployment environment (dev, staging, prod)"
  type        = string
}

variable "tags" {
  description = "Default tags applied to all resources"
  type        = map(string)
  default     = {}
}

variable "vpc_id" {
  description = "VPC ID where the ALB is deployed"
  type        = string
}

variable "public_subnet_ids" {
  description = "List of public subnet IDs for the ALB"
  type        = list(string)
}

variable "sg_alb_id" {
  description = "Security group ID for the ALB"
  type        = string
}

variable "acm_certificate_arn" {
  description = "ARN of the ACM certificate for HTTPS listener. Leave empty to skip OIDC auth rules."
  type        = string
  default     = ""
}

variable "cognito_user_pool_id" {
  description = "Cognito user pool ID for OIDC authentication"
  type        = string
  default     = ""
}

variable "cognito_client_id" {
  description = "Cognito app client ID for OIDC authentication"
  type        = string
  default     = ""
}

variable "cognito_client_secret" {
  description = "Cognito app client secret for OIDC authentication"
  type        = string
  sensitive   = true
  default     = ""
}

variable "cognito_domain" {
  description = "Cognito user pool domain prefix for OIDC endpoints"
  type        = string
  default     = ""
}

variable "waf_acl_arn" {
  description = "ARN of the WAF WebACL to associate with the ALB. Leave empty to skip WAF association."
  type        = string
  default     = ""
}
