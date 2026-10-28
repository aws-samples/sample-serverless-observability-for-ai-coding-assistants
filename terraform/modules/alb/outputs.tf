# ALB Module Outputs

output "alb_arn" {
  description = "ARN of the Application Load Balancer"
  value       = aws_lb.main.arn
}

output "alb_dns_name" {
  description = "DNS name of the Application Load Balancer"
  value       = aws_lb.main.dns_name
}

output "target_group_arn" {
  description = "ARN of the collector target group"
  value       = aws_lb_target_group.collector.arn
}

output "listener_arn" {
  description = "ARN of the HTTPS listener"
  value       = aws_lb_listener.https.arn
}

output "self_signed_certificate_pem" {
  description = "PEM of the self-signed listener certificate; empty when acm_certificate_arn is set"
  value       = local.has_acm_cert ? "" : tls_self_signed_cert.self_signed[0].cert_pem
}
