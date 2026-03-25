# Grafana Module Outputs

output "workspace_id" {
  description = "ID of the Managed Grafana workspace"
  value       = aws_grafana_workspace.main.id
}

output "workspace_url" {
  description = "URL of the Managed Grafana workspace"
  value       = "https://${aws_grafana_workspace.main.endpoint}"
}

output "workspace_arn" {
  description = "ARN of the Managed Grafana workspace"
  value       = aws_grafana_workspace.main.arn
}
