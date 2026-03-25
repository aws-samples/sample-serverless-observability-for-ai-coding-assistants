# ECS Collector Module — OTel Collector on ECS Fargate
# Manages ECS cluster, service, task definition, and auto-scaling
# Requirements: 2.4, 2.7, 3.1-3.8, 7.8-7.11, 11.1, 11.2, 11.6, 11.7

data "aws_region" "current" {}

# -----------------------------------------------------------------------------
# ECR Repository — auto-created so users don't need a pre-existing image URI
# -----------------------------------------------------------------------------
resource "aws_ecr_repository" "collector" {
  name                 = "${var.project_name}-collector-${var.environment}"
  image_tag_mutability = "MUTABLE"
  force_delete         = true

  image_scanning_configuration {
    scan_on_push = true
  }

  tags = var.tags
}

locals {
  aws_region      = data.aws_region.current.id
  collector_image = var.collector_image != "" ? var.collector_image : "${aws_ecr_repository.collector.repository_url}:latest"
}

# -----------------------------------------------------------------------------
# CloudWatch Log Group
# -----------------------------------------------------------------------------
resource "aws_cloudwatch_log_group" "collector" {
  name              = "/ecs/${var.project_name}-collector-${var.environment}"
  retention_in_days = 30
  tags              = var.tags
}

# -----------------------------------------------------------------------------
# ECS Cluster
# -----------------------------------------------------------------------------
resource "aws_ecs_cluster" "main" {
  name = "${var.project_name}-cluster-${var.environment}"

  setting {
    name  = "containerInsights"
    value = "enabled"
  }

  tags = var.tags
}

# -----------------------------------------------------------------------------
# ECS Task Definition
# 1 vCPU, 2 GB memory, OTel Collector container
# -----------------------------------------------------------------------------
resource "aws_ecs_task_definition" "collector" {
  family                   = "${var.project_name}-collector-${var.environment}"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = 1024
  memory                   = 2048
  task_role_arn            = var.task_role_arn
  execution_role_arn       = var.execution_role_arn

  container_definitions = jsonencode([
    {
      name      = "otel-collector"
      image     = local.collector_image
      essential = true

      portMappings = [
        { containerPort = 4318, protocol = "tcp" },
        { containerPort = 13133, protocol = "tcp" }
      ]

      environment = [
        { name = "AWS_REGION", value = local.aws_region },
        { name = "TELEMETRY_API_KEY", value = var.telemetry_api_key },
        { name = "KINESIS_METRICS_STREAM", value = var.kinesis_metrics_stream },
        { name = "KINESIS_LOGS_STREAM", value = var.kinesis_logs_stream }
      ]

      logConfiguration = {
        logDriver = "awslogs"
        options = {
          "awslogs-group"         = aws_cloudwatch_log_group.collector.name
          "awslogs-region"        = local.aws_region
          "awslogs-stream-prefix" = "collector"
        }
      }
    }
  ])

  tags = var.tags
}

# -----------------------------------------------------------------------------
# ECS Service — desired count 2, multi-AZ, ALB target group attachment
# -----------------------------------------------------------------------------
resource "aws_ecs_service" "collector" {
  name            = "${var.project_name}-collector-${var.environment}"
  cluster         = aws_ecs_cluster.main.id
  task_definition = aws_ecs_task_definition.collector.arn
  desired_count   = 2
  launch_type     = "FARGATE"

  network_configuration {
    subnets          = var.private_subnet_ids
    security_groups  = [var.sg_collector_id]
    assign_public_ip = false
  }

  load_balancer {
    target_group_arn = var.target_group_arn
    container_name   = "otel-collector"
    container_port   = 4318
  }

  lifecycle {
    ignore_changes = [desired_count]
  }

  tags = var.tags
}

# -----------------------------------------------------------------------------
# Auto-Scaling — target tracking on CPU (target 60%), min 2, max 20
# -----------------------------------------------------------------------------
resource "aws_appautoscaling_target" "collector" {
  max_capacity       = 20
  min_capacity       = 2
  resource_id        = "service/${aws_ecs_cluster.main.name}/${aws_ecs_service.collector.name}"
  scalable_dimension = "ecs:service:DesiredCount"
  service_namespace  = "ecs"
}

resource "aws_appautoscaling_policy" "collector_cpu" {
  name               = "${var.project_name}-collector-cpu-${var.environment}"
  policy_type        = "TargetTrackingScaling"
  resource_id        = aws_appautoscaling_target.collector.resource_id
  scalable_dimension = aws_appautoscaling_target.collector.scalable_dimension
  service_namespace  = aws_appautoscaling_target.collector.service_namespace

  target_tracking_scaling_policy_configuration {
    predefined_metric_specification {
      predefined_metric_type = "ECSServiceAverageCPUUtilization"
    }
    target_value = 60.0
  }
}
