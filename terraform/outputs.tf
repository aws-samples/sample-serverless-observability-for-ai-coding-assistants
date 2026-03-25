# Root Outputs

output "otlp_endpoint_url" {
  description = "ALB DNS name — the OTLP ingestion endpoint"
  value       = "https://${module.alb.alb_dns_name}"
}

output "grafana_workspace_url" {
  description = "Amazon Managed Grafana workspace URL"
  value       = module.grafana.workspace_url
}

output "ecr_repository_url" {
  description = "ECR repository URL — push the collector image here"
  value       = module.ecs_collector.ecr_repository_url
}

output "archive_bucket_name" {
  description = "S3 bucket for telemetry archive"
  value       = aws_s3_bucket.telemetry_archive.id
}

output "athena_workgroup" {
  description = "Athena workgroup for querying telemetry"
  value       = aws_athena_workgroup.telemetry.name
}
