# WAF Module — AWS WAFv2 Web ACL
# Rate limiting and AWS managed rule protection for the ALB
# Requirements: 7.1, 7.6

resource "aws_wafv2_web_acl" "main" {
  name        = "${var.project_name}-waf-${var.environment}"
  description = "WAF WebACL for ALB rate limiting and common exploit protection"
  scope       = "REGIONAL"

  default_action {
    allow {}
  }

  # --- Rate limiting: 2000 requests per 5 minutes per IP ---
  rule {
    name     = "rate-limit-per-ip"
    priority = 1

    action {
      block {}
    }

    statement {
      rate_based_statement {
        limit              = 2000
        aggregate_key_type = "IP"
      }
    }

    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "${var.project_name}-rate-limit-${var.environment}"
      sampled_requests_enabled   = true
    }
  }

  # --- AWS Managed Rules: Common Rule Set ---
  rule {
    name     = "aws-managed-common-rules"
    priority = 2

    override_action {
      none {}
    }

    statement {
      managed_rule_group_statement {
        name        = "AWSManagedRulesCommonRuleSet"
        vendor_name = "AWS"
      }
    }

    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "${var.project_name}-common-rules-${var.environment}"
      sampled_requests_enabled   = true
    }
  }

  visibility_config {
    cloudwatch_metrics_enabled = true
    metric_name                = "${var.project_name}-waf-${var.environment}"
    sampled_requests_enabled   = true
  }

  tags = var.tags
}
