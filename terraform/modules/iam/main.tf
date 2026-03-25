# IAM Module — Identity and access management

data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

locals {
  name_prefix = "${var.project_name}-${var.environment}"
}

# =============================================================================
# 1. OTel Collector Task Role — Kinesis write + CloudWatch Logs
# =============================================================================
resource "aws_iam_role" "otel_collector_task_role" {
  name = "${local.name_prefix}-otel-collector-task-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ecs-tasks.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
  tags = merge(var.tags, { Name = "${local.name_prefix}-otel-collector-task-role" })
}

resource "aws_iam_role_policy" "otel_collector_task_policy" {
  name = "${local.name_prefix}-otel-collector-task-policy"
  role = aws_iam_role.otel_collector_task_role.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "KinesisPut"
        Effect   = "Allow"
        Action   = ["kinesis:PutRecord", "kinesis:PutRecords", "kinesis:DescribeStream"]
        Resource = [var.kinesis_metrics_arn, var.kinesis_logs_arn]
      }
    ]
  })
}

# =============================================================================
# 2. OTel Collector Execution Role — ECR pull + container logs
# =============================================================================
resource "aws_iam_role" "otel_collector_execution_role" {
  name = "${local.name_prefix}-otel-collector-execution-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ecs-tasks.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
  tags = merge(var.tags, { Name = "${local.name_prefix}-otel-collector-execution-role" })
}

resource "aws_iam_role_policy" "otel_collector_execution_policy" {
  name = "${local.name_prefix}-otel-collector-execution-policy"
  role = aws_iam_role.otel_collector_execution_role.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "ECRAuth"
        Effect   = "Allow"
        Action   = ["ecr:GetAuthorizationToken"]
        Resource = ["*"]
      },
      {
        Sid      = "ECRPull"
        Effect   = "Allow"
        Action   = ["ecr:BatchCheckLayerAvailability", "ecr:GetDownloadUrlForLayer", "ecr:BatchGetImage"]
        Resource = ["*"]
      },
      {
        Sid      = "CloudWatchLogs"
        Effect   = "Allow"
        Action   = ["logs:CreateLogStream", "logs:PutLogEvents", "logs:CreateLogGroup"]
        Resource = ["arn:aws:logs:${data.aws_region.current.id}:${data.aws_caller_identity.current.account_id}:log-group:/ecs/${var.project_name}-*:*"]
      }
    ]
  })
}

# =============================================================================
# 3. Grafana Workspace Role — Athena + S3 + CloudWatch read
# =============================================================================
resource "aws_iam_role" "grafana_workspace_role" {
  name = "${local.name_prefix}-grafana-workspace-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "grafana.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
  tags = merge(var.tags, { Name = "${local.name_prefix}-grafana-workspace-role" })
}

resource "aws_iam_role_policy" "grafana_workspace_policy" {
  name = "${local.name_prefix}-grafana-workspace-policy"
  role = aws_iam_role.grafana_workspace_role.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "AthenaQuery"
        Effect = "Allow"
        Action = [
          "athena:StartQueryExecution", "athena:GetQueryExecution",
          "athena:GetQueryResults", "athena:StopQueryExecution",
          "athena:ListWorkGroups", "athena:GetWorkGroup",
          "athena:ListDataCatalogs", "athena:ListDatabases",
          "athena:ListTableMetadata", "athena:GetTableMetadata",
          "athena:GetDataCatalog", "athena:GetDatabase"
        ]
        Resource = ["*"]
      },
      {
        Sid    = "GlueCatalog"
        Effect = "Allow"
        Action = ["glue:GetTable", "glue:GetTables", "glue:GetDatabase", "glue:GetDatabases", "glue:GetPartitions"]
        Resource = [
          "arn:aws:glue:${data.aws_region.current.id}:${data.aws_caller_identity.current.account_id}:catalog",
          "arn:aws:glue:${data.aws_region.current.id}:${data.aws_caller_identity.current.account_id}:database/claude_code_telemetry_*",
          "arn:aws:glue:${data.aws_region.current.id}:${data.aws_caller_identity.current.account_id}:table/claude_code_telemetry_*/*"
        ]
      },
      {
        Sid      = "S3Read"
        Effect   = "Allow"
        Action   = ["s3:GetObject", "s3:ListBucket", "s3:GetBucketLocation"]
        Resource = [var.archive_bucket_arn, "${var.archive_bucket_arn}/*"]
      },
      {
        Sid      = "S3AthenaResults"
        Effect   = "Allow"
        Action   = ["s3:PutObject", "s3:GetObject"]
        Resource = ["${var.archive_bucket_arn}/athena-results/*"]
      },
      {
        Sid    = "CloudWatchRead"
        Effect = "Allow"
        Action = [
          "logs:DescribeLogGroups", "logs:StartQuery", "logs:StopQuery",
          "logs:GetQueryResults", "logs:GetLogEvents", "logs:FilterLogEvents",
          "cloudwatch:GetMetricData", "cloudwatch:ListMetrics"
        ]
        Resource = ["*"]
      }
    ]
  })
}
