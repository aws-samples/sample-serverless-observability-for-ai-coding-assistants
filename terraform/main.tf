# -----------------------------------------------------------------------------
# Root Module — Claude Code Telemetry Platform
# Architecture: Collector → Kinesis → Firehose → S3 (Parquet) → Athena → Grafana
# -----------------------------------------------------------------------------

data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

locals {
  name_prefix = "${var.project_name}-${var.environment}"
}

# -----------------------------------------------------------------------------
# 1. Networking
# -----------------------------------------------------------------------------
module "vpc" {
  source = "./modules/vpc"

  environment           = var.environment
  project_name          = var.project_name
  corporate_cidr_blocks = var.corporate_cidr_blocks
  tags                  = var.tags
}

# -----------------------------------------------------------------------------
# 2. IAM
# -----------------------------------------------------------------------------
module "iam" {
  source = "./modules/iam"

  project_name        = var.project_name
  environment         = var.environment
  tags                = var.tags
  kinesis_metrics_arn = aws_kinesis_stream.metrics.arn
  kinesis_logs_arn    = aws_kinesis_stream.logs.arn
  archive_bucket_arn  = aws_s3_bucket.telemetry_archive.arn
}

# -----------------------------------------------------------------------------
# 3. WAF
# -----------------------------------------------------------------------------
module "waf" {
  source = "./modules/waf"

  project_name = var.project_name
  environment  = var.environment
  tags         = var.tags
}

# -----------------------------------------------------------------------------
# 4. Application Load Balancer
# -----------------------------------------------------------------------------
module "alb" {
  source = "./modules/alb"

  project_name        = var.project_name
  environment         = var.environment
  tags                = var.tags
  vpc_id              = module.vpc.vpc_id
  public_subnet_ids   = module.vpc.public_subnet_ids
  sg_alb_id           = module.vpc.sg_alb_id
  acm_certificate_arn = var.acm_certificate_arn
  waf_acl_arn         = module.waf.web_acl_arn
}

# -----------------------------------------------------------------------------
# 5. ECS Fargate — OTel Collector
# -----------------------------------------------------------------------------
module "ecs_collector" {
  source = "./modules/ecs-collector"

  project_name       = var.project_name
  environment        = var.environment
  tags               = var.tags
  private_subnet_ids = module.vpc.private_subnet_ids
  sg_collector_id    = module.vpc.sg_collector_id
  target_group_arn   = module.alb.target_group_arn
  task_role_arn      = module.iam.otel_collector_task_role_arn
  execution_role_arn = module.iam.otel_collector_execution_role_arn
  collector_image    = var.collector_image
  telemetry_api_key  = var.telemetry_api_key

  kinesis_metrics_stream = aws_kinesis_stream.metrics.name
  kinesis_logs_stream    = aws_kinesis_stream.logs.name
}

# -----------------------------------------------------------------------------
# 6. Amazon Managed Grafana
# -----------------------------------------------------------------------------
module "grafana" {
  source = "./modules/grafana"

  project_name           = var.project_name
  environment            = var.environment
  tags                   = var.tags
  grafana_role_arn       = module.iam.grafana_workspace_role_arn
  sg_grafana_id          = module.vpc.sg_grafana_id
  private_subnet_ids     = module.vpc.private_subnet_ids
  grafana_auth_provider  = var.grafana_auth_provider
  grafana_workspace_name = var.grafana_workspace_name
}

# -----------------------------------------------------------------------------
# 7. S3 Telemetry Archive
# -----------------------------------------------------------------------------
resource "aws_s3_bucket" "telemetry_archive" {
  bucket        = "${local.name_prefix}-archive-${data.aws_caller_identity.current.account_id}"
  force_destroy = true
  tags          = var.tags
}

resource "aws_s3_bucket_versioning" "archive" {
  bucket = aws_s3_bucket.telemetry_archive.id
  versioning_configuration { status = "Enabled" }
}

resource "aws_s3_bucket_public_access_block" "archive" {
  bucket                  = aws_s3_bucket.telemetry_archive.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "archive" {
  bucket = aws_s3_bucket.telemetry_archive.id
  rule {
    apply_server_side_encryption_by_default { sse_algorithm = "AES256" }
    bucket_key_enabled = true
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "archive" {
  bucket = aws_s3_bucket.telemetry_archive.id
  rule {
    id     = "archive-and-expire"
    status = "Enabled"
    filter {}
    transition {
      days          = 90
      storage_class = "GLACIER"
    }
    expiration {
      days = 365
    }
  }
}

# -----------------------------------------------------------------------------
# 8. Kinesis Data Streams
# -----------------------------------------------------------------------------
resource "aws_kinesis_stream" "metrics" {
  name             = "${local.name_prefix}-metrics"
  retention_period = 24

  stream_mode_details {
    stream_mode = "ON_DEMAND"
  }

  tags = var.tags
}

resource "aws_kinesis_stream" "logs" {
  name             = "${local.name_prefix}-logs"
  retention_period = 24

  stream_mode_details {
    stream_mode = "ON_DEMAND"
  }

  tags = var.tags
}

# -----------------------------------------------------------------------------
# 9. Firehose Delivery Streams (Kinesis → S3 Parquet)
# -----------------------------------------------------------------------------
resource "aws_iam_role" "firehose" {
  name = "${local.name_prefix}-firehose"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "firehose.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
  tags = var.tags
}

resource "aws_iam_role_policy" "firehose" {
  name = "${local.name_prefix}-firehose"
  role = aws_iam_role.firehose.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "S3Write"
        Effect   = "Allow"
        Action   = ["s3:PutObject", "s3:PutObjectAcl", "s3:GetBucketLocation", "s3:ListBucket"]
        Resource = [aws_s3_bucket.telemetry_archive.arn, "${aws_s3_bucket.telemetry_archive.arn}/*"]
      },
      {
        Sid      = "KinesisRead"
        Effect   = "Allow"
        Action   = ["kinesis:DescribeStream", "kinesis:GetShardIterator", "kinesis:GetRecords", "kinesis:ListShards"]
        Resource = [aws_kinesis_stream.metrics.arn, aws_kinesis_stream.logs.arn]
      },
      {
        Sid    = "GlueCatalog"
        Effect = "Allow"
        Action = ["glue:GetTable", "glue:GetTableVersion", "glue:GetTableVersions"]
        Resource = [
          "arn:aws:glue:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:catalog",
          "arn:aws:glue:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:database/${aws_glue_catalog_database.telemetry.name}",
          "arn:aws:glue:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:table/${aws_glue_catalog_database.telemetry.name}/*"
        ]
      },
      {
        Sid      = "CloudWatchLogs"
        Effect   = "Allow"
        Action   = ["logs:PutLogEvents"]
        Resource = ["arn:aws:logs:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:log-group:/aws/firehose/${local.name_prefix}-*:*"]
      },
      {
        Sid      = "LambdaInvoke"
        Effect   = "Allow"
        Action   = ["lambda:InvokeFunction", "lambda:GetFunctionConfiguration"]
        Resource = ["arn:aws:lambda:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:function:${local.name_prefix}-flatten-otlp*"]
      }
    ]
  })
}

resource "aws_cloudwatch_log_group" "firehose_metrics" {
  name              = "/aws/firehose/${local.name_prefix}-metrics"
  retention_in_days = 14
  tags              = var.tags
}

resource "aws_cloudwatch_log_group" "firehose_logs" {
  name              = "/aws/firehose/${local.name_prefix}-logs"
  retention_in_days = 14
  tags              = var.tags
}

resource "aws_kinesis_firehose_delivery_stream" "metrics" {
  name        = "${local.name_prefix}-metrics-to-s3"
  destination = "extended_s3"

  kinesis_source_configuration {
    kinesis_stream_arn = aws_kinesis_stream.metrics.arn
    role_arn           = aws_iam_role.firehose.arn
  }

  extended_s3_configuration {
    role_arn            = aws_iam_role.firehose.arn
    bucket_arn          = aws_s3_bucket.telemetry_archive.arn
    prefix              = "metrics/year=!{timestamp:yyyy}/month=!{timestamp:MM}/day=!{timestamp:dd}/"
    error_output_prefix = "errors/metrics/"
    buffering_size      = 64
    buffering_interval  = 300
    compression_format  = "UNCOMPRESSED"

    data_format_conversion_configuration {
      enabled = true
      input_format_configuration {
        deserializer {
          open_x_json_ser_de {}
        }
      }
      output_format_configuration {
        serializer {
          parquet_ser_de {
            compression = "SNAPPY"
          }
        }
      }
      schema_configuration {
        database_name = aws_glue_catalog_database.telemetry.name
        table_name    = aws_glue_catalog_table.metrics.name
        role_arn      = aws_iam_role.firehose.arn
      }
    }

    cloudwatch_logging_options {
      enabled         = true
      log_group_name  = aws_cloudwatch_log_group.firehose_metrics.name
      log_stream_name = "errors"
    }

    processing_configuration {
      enabled = true
      processors {
        type = "Lambda"
        parameters {
          parameter_name  = "LambdaArn"
          parameter_value = "${aws_lambda_function.flatten.arn}:$LATEST"
        }
        parameters {
          parameter_name  = "BufferSizeInMBs"
          parameter_value = "1"
        }
        parameters {
          parameter_name  = "BufferIntervalInSeconds"
          parameter_value = "60"
        }
      }
    }
  }

  tags = var.tags
}

resource "aws_kinesis_firehose_delivery_stream" "logs" {
  name        = "${local.name_prefix}-logs-to-s3"
  destination = "extended_s3"

  kinesis_source_configuration {
    kinesis_stream_arn = aws_kinesis_stream.logs.arn
    role_arn           = aws_iam_role.firehose.arn
  }

  extended_s3_configuration {
    role_arn            = aws_iam_role.firehose.arn
    bucket_arn          = aws_s3_bucket.telemetry_archive.arn
    prefix              = "logs/year=!{timestamp:yyyy}/month=!{timestamp:MM}/day=!{timestamp:dd}/"
    error_output_prefix = "errors/logs/"
    buffering_size      = 64
    buffering_interval  = 300
    compression_format  = "UNCOMPRESSED"

    data_format_conversion_configuration {
      enabled = true
      input_format_configuration {
        deserializer {
          open_x_json_ser_de {}
        }
      }
      output_format_configuration {
        serializer {
          parquet_ser_de {
            compression = "SNAPPY"
          }
        }
      }
      schema_configuration {
        database_name = aws_glue_catalog_database.telemetry.name
        table_name    = aws_glue_catalog_table.logs.name
        role_arn      = aws_iam_role.firehose.arn
      }
    }

    cloudwatch_logging_options {
      enabled         = true
      log_group_name  = aws_cloudwatch_log_group.firehose_logs.name
      log_stream_name = "errors"
    }

    processing_configuration {
      enabled = true
      processors {
        type = "Lambda"
        parameters {
          parameter_name  = "LambdaArn"
          parameter_value = "${aws_lambda_function.flatten.arn}:$LATEST"
        }
        parameters {
          parameter_name  = "BufferSizeInMBs"
          parameter_value = "1"
        }
        parameters {
          parameter_name  = "BufferIntervalInSeconds"
          parameter_value = "60"
        }
      }
    }
  }

  tags = var.tags
}

# -----------------------------------------------------------------------------
# 10. Glue Data Catalog + Athena
# -----------------------------------------------------------------------------
resource "aws_glue_catalog_database" "telemetry" {
  name        = "claude_code_telemetry_${var.environment}"
  description = "Claude Code telemetry data lake"
}

resource "aws_glue_catalog_table" "metrics" {
  name          = "metrics"
  database_name = aws_glue_catalog_database.telemetry.name
  table_type    = "EXTERNAL_TABLE"

  parameters = {
    "classification"            = "parquet"
    "projection.enabled"        = "true"
    "projection.year.type"      = "integer"
    "projection.year.range"     = "2024,2040"
    "projection.year.digits"    = "4"
    "projection.month.type"     = "integer"
    "projection.month.range"    = "1,12"
    "projection.month.digits"   = "2"
    "projection.day.type"       = "integer"
    "projection.day.range"      = "1,31"
    "projection.day.digits"     = "2"
    "storage.location.template" = "s3://${aws_s3_bucket.telemetry_archive.id}/metrics/year=$${year}/month=$${month}/day=$${day}/"
  }

  partition_keys {
    name = "year"
    type = "int"
  }
  partition_keys {
    name = "month"
    type = "int"
  }
  partition_keys {
    name = "day"
    type = "int"
  }

  storage_descriptor {
    location      = "s3://${aws_s3_bucket.telemetry_archive.id}/metrics/"
    input_format  = "org.apache.hadoop.hive.ql.io.parquet.MapredParquetInputFormat"
    output_format = "org.apache.hadoop.hive.ql.io.parquet.MapredParquetOutputFormat"

    ser_de_info {
      serialization_library = "org.apache.hadoop.hive.ql.io.parquet.serde.ParquetHiveSerDe"
      parameters            = { "serialization.format" = "1" }
    }

    columns {
      name = "metric_name"
      type = "string"
    }
    columns {
      name = "metric_value"
      type = "double"
    }
    columns {
      name = "service_name"
      type = "string"
    }
    columns {
      name = "service_version"
      type = "string"
    }
    columns {
      name = "host_arch"
      type = "string"
    }
    columns {
      name = "os_type"
      type = "string"
    }
    columns {
      name = "user_id"
      type = "string"
    }
    columns {
      name = "session_id"
      type = "string"
    }
    columns {
      name = "terminal_type"
      type = "string"
    }
    columns {
      name = "model"
      type = "string"
    }
    columns {
      name = "type"
      type = "string"
    }
  }
}

resource "aws_glue_catalog_table" "logs" {
  name          = "logs"
  database_name = aws_glue_catalog_database.telemetry.name
  table_type    = "EXTERNAL_TABLE"

  parameters = {
    "classification"            = "parquet"
    "projection.enabled"        = "true"
    "projection.year.type"      = "integer"
    "projection.year.range"     = "2024,2040"
    "projection.year.digits"    = "4"
    "projection.month.type"     = "integer"
    "projection.month.range"    = "1,12"
    "projection.month.digits"   = "2"
    "projection.day.type"       = "integer"
    "projection.day.range"      = "1,31"
    "projection.day.digits"     = "2"
    "storage.location.template" = "s3://${aws_s3_bucket.telemetry_archive.id}/logs/year=$${year}/month=$${month}/day=$${day}/"
  }

  partition_keys {
    name = "year"
    type = "int"
  }
  partition_keys {
    name = "month"
    type = "int"
  }
  partition_keys {
    name = "day"
    type = "int"
  }

  storage_descriptor {
    location      = "s3://${aws_s3_bucket.telemetry_archive.id}/logs/"
    input_format  = "org.apache.hadoop.hive.ql.io.parquet.MapredParquetInputFormat"
    output_format = "org.apache.hadoop.hive.ql.io.parquet.MapredParquetOutputFormat"

    ser_de_info {
      serialization_library = "org.apache.hadoop.hive.ql.io.parquet.serde.ParquetHiveSerDe"
      parameters            = { "serialization.format" = "1" }
    }

    columns {
      name = "event_type"
      type = "string"
    }
    columns {
      name = "event_name"
      type = "string"
    }
    columns {
      name = "event_timestamp"
      type = "string"
    }
    columns {
      name = "event_sequence"
      type = "string"
    }
    columns {
      name = "user_id"
      type = "string"
    }
    columns {
      name = "session_id"
      type = "string"
    }
    columns {
      name = "terminal_type"
      type = "string"
    }
    columns {
      name = "prompt_id"
      type = "string"
    }
    columns {
      name = "prompt"
      type = "string"
    }
    columns {
      name = "prompt_length"
      type = "string"
    }
    columns {
      name = "model"
      type = "string"
    }
    columns {
      name = "cost_usd"
      type = "string"
    }
    columns {
      name = "input_tokens"
      type = "string"
    }
    columns {
      name = "output_tokens"
      type = "string"
    }
    columns {
      name = "cache_read_tokens"
      type = "string"
    }
    columns {
      name = "cache_creation_tokens"
      type = "string"
    }
    columns {
      name = "duration_ms"
      type = "string"
    }
    columns {
      name = "tool_name"
      type = "string"
    }
    columns {
      name = "decision"
      type = "string"
    }
    columns {
      name = "speed"
      type = "string"
    }
    columns {
      name = "service_name"
      type = "string"
    }
    columns {
      name = "service_version"
      type = "string"
    }
    columns {
      name = "host_arch"
      type = "string"
    }
    columns {
      name = "os_type"
      type = "string"
    }
  }
}

resource "aws_athena_workgroup" "telemetry" {
  name          = local.name_prefix
  force_destroy = true

  configuration {
    enforce_workgroup_configuration = true
    result_configuration {
      output_location = "s3://${aws_s3_bucket.telemetry_archive.id}/athena-results/"
      encryption_configuration {
        encryption_option = "SSE_S3"
      }
    }
    bytes_scanned_cutoff_per_query = 10737418240
  }

  tags = var.tags
}

# -----------------------------------------------------------------------------
# 11. Lambda — OTLP JSON flattener for Firehose
# -----------------------------------------------------------------------------
data "archive_file" "flatten_lambda" {
  type        = "zip"
  source_file = "${path.module}/lambda/flatten.py"
  output_path = "${path.module}/lambda/flatten.zip"
}

resource "aws_iam_role" "flatten_lambda" {
  name = "${local.name_prefix}-flatten-lambda"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
  tags = var.tags
}

resource "aws_iam_role_policy_attachment" "flatten_lambda_logs" {
  role       = aws_iam_role.flatten_lambda.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

resource "aws_lambda_function" "flatten" {
  function_name    = "${local.name_prefix}-flatten-otlp"
  role             = aws_iam_role.flatten_lambda.arn
  handler          = "flatten.handler"
  runtime          = "python3.12"
  timeout          = 300
  memory_size      = 256
  filename         = data.archive_file.flatten_lambda.output_path
  source_code_hash = data.archive_file.flatten_lambda.output_base64sha256

  tags = var.tags
}
