# ECS Collector Module Variables

variable "project_name" { type = string }
variable "environment" { type = string }

variable "tags" {
  type    = map(string)
  default = {}
}

variable "private_subnet_ids" { type = list(string) }
variable "sg_collector_id" { type = string }
variable "target_group_arn" { type = string }
variable "task_role_arn" { type = string }
variable "execution_role_arn" { type = string }

variable "collector_image" {
  type    = string
  default = ""
}

variable "telemetry_api_key" {
  type      = string
  sensitive = true
}

variable "kinesis_metrics_stream" {
  description = "Kinesis Data Stream name for metrics"
  type        = string
}

variable "kinesis_logs_stream" {
  description = "Kinesis Data Stream name for logs"
  type        = string
}
