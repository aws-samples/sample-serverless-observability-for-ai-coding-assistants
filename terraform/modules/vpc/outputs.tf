# VPC Module Outputs

output "vpc_id" {
  description = "ID of the VPC"
  value       = aws_vpc.main.id
}

output "public_subnet_ids" {
  description = "List of public subnet IDs"
  value       = aws_subnet.public[*].id
}

output "private_subnet_ids" {
  description = "List of private subnet IDs"
  value       = aws_subnet.private[*].id
}

output "sg_alb_id" {
  description = "Security group ID for the ALB"
  value       = aws_security_group.alb.id
}

output "sg_collector_id" {
  description = "Security group ID for the OTel Collector"
  value       = aws_security_group.collector.id
}

output "sg_grafana_id" {
  description = "Security group ID for Grafana"
  value       = aws_security_group.grafana.id
}

output "sg_vpc_endpoints_id" {
  description = "Security group ID for VPC endpoints"
  value       = aws_security_group.vpc_endpoints.id
}
