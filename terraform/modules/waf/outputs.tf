# WAF Module Outputs

output "web_acl_arn" {
  description = "ARN of the WAFv2 WebACL"
  value       = aws_wafv2_web_acl.main.arn
}
