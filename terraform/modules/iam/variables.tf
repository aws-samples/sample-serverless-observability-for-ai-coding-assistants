# IAM Module Variables

variable "project_name" { type = string }
variable "environment" { type = string }

variable "tags" {
  type    = map(string)
  default = {}
}

variable "kinesis_metrics_arn" {
  description = "ARN of the Kinesis metrics stream"
  type        = string
}

variable "kinesis_logs_arn" {
  description = "ARN of the Kinesis logs stream"
  type        = string
}

variable "archive_bucket_arn" {
  description = "ARN of the S3 telemetry archive bucket"
  type        = string
}
