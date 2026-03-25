# IAM Module Outputs

output "otel_collector_task_role_arn" {
  description = "ARN of the OTel Collector ECS task role"
  value       = aws_iam_role.otel_collector_task_role.arn
}

output "otel_collector_execution_role_arn" {
  description = "ARN of the OTel Collector ECS execution role"
  value       = aws_iam_role.otel_collector_execution_role.arn
}

output "grafana_workspace_role_arn" {
  description = "ARN of the Grafana workspace IAM role"
  value       = aws_iam_role.grafana_workspace_role.arn
}
