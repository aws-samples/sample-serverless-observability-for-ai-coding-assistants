# ALB Module — Application Load Balancer
# Manages the public OTLP ingestion endpoint with TLS termination and JWT validation
# Requirements: 2.1, 2.2, 2.3, 2.5, 2.7, 2.8, 2.9, 7.1, 7.6, 7.7, 8.6, 9.10

locals {
  aws_region            = data.aws_region.current.id
  has_acm_cert          = var.acm_certificate_arn != ""
  cognito_oidc_endpoint = "https://cognito-idp.${local.aws_region}.amazonaws.com/${var.cognito_user_pool_id}"
}

data "aws_region" "current" {}

# Prevent silent misconfiguration: Cognito without ACM means zero ALB-layer auth.
# OIDC listener rules require a valid ACM certificate (ALB requirement).
check "cognito_requires_acm" {
  assert {
    condition     = var.cognito_user_pool_id == "" || local.has_acm_cert
    error_message = "cognito_user_pool_id is set but acm_certificate_arn is empty. OIDC auth rules require an ACM certificate — without one, all traffic is forwarded without identity checks."
  }
}

# -----------------------------------------------------------------------------
# Application Load Balancer
# -----------------------------------------------------------------------------
resource "aws_lb" "main" {
  name               = "${var.project_name}-alb-${var.environment}"
  internal           = false
  load_balancer_type = "application"
  security_groups    = [var.sg_alb_id]
  subnets            = var.public_subnet_ids

  idle_timeout               = 60
  enable_deletion_protection = false # Set to true for production

  tags = var.tags
}

# -----------------------------------------------------------------------------
# Target Group — ECS Fargate OTel Collector (HTTP/protobuf)
# -----------------------------------------------------------------------------
resource "aws_lb_target_group" "collector" {
  name             = "${var.project_name}-col-${var.environment}"
  port             = 4318
  protocol         = "HTTP"
  protocol_version = "HTTP1"
  vpc_id           = var.vpc_id
  target_type      = "ip"

  health_check {
    enabled             = true
    path                = "/health"
    port                = "13133"
    protocol            = "HTTP"
    matcher             = "200"
    interval            = 30
    timeout             = 5
    healthy_threshold   = 2
    unhealthy_threshold = 3
  }

  stickiness {
    enabled = false
    type    = "lb_cookie"
  }

  tags = var.tags
}

# -----------------------------------------------------------------------------
# Self-signed TLS certificate — used when no ACM certificate is provided
# -----------------------------------------------------------------------------
resource "tls_private_key" "self_signed" {
  count     = local.has_acm_cert ? 0 : 1
  algorithm = "RSA"
  rsa_bits  = 2048
}

resource "tls_self_signed_cert" "self_signed" {
  count           = local.has_acm_cert ? 0 : 1
  private_key_pem = tls_private_key.self_signed[0].private_key_pem

  subject {
    common_name  = "telemetry.dev.internal"
    organization = var.project_name
  }

  validity_period_hours = 8760 # 1 year

  allowed_uses = [
    "key_encipherment",
    "digital_signature",
    "server_auth",
  ]
}

resource "aws_acm_certificate" "self_signed" {
  count            = local.has_acm_cert ? 0 : 1
  private_key      = tls_private_key.self_signed[0].private_key_pem
  certificate_body = tls_self_signed_cert.self_signed[0].cert_pem

  tags = var.tags
}

# -----------------------------------------------------------------------------
# HTTPS Listener (port 443, TLS 1.2+)
# When no ACM cert is provided, uses a self-signed cert and forwards all traffic.
# -----------------------------------------------------------------------------
resource "aws_lb_listener" "https" {
  load_balancer_arn = aws_lb.main.arn
  port              = 443
  protocol          = "HTTPS"
  ssl_policy        = "ELBSecurityPolicy-TLS13-1-2-2021-06"
  certificate_arn   = local.has_acm_cert ? var.acm_certificate_arn : aws_acm_certificate.self_signed[0].arn

  # Default action: forward to collector target group
  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.collector.arn
  }

  tags = var.tags
}

# -----------------------------------------------------------------------------
# Listener Rule: HTTP/protobuf traffic — OIDC auth then forward
# Only created when an ACM certificate is provided (i.e. custom domain flow).
# Without a cert, all traffic is forwarded directly by the default action.
# -----------------------------------------------------------------------------
resource "aws_lb_listener_rule" "http_protobuf_oidc" {
  count        = local.has_acm_cert && var.cognito_user_pool_id != "" ? 1 : 0
  listener_arn = aws_lb_listener.https.arn
  priority     = 10

  action {
    type = "authenticate-oidc"

    authenticate_oidc {
      authorization_endpoint = "https://${var.cognito_domain}.auth.${local.aws_region}.amazoncognito.com/oauth2/authorize"
      client_id              = var.cognito_client_id
      client_secret          = var.cognito_client_secret
      issuer                 = local.cognito_oidc_endpoint
      token_endpoint         = "https://${var.cognito_domain}.auth.${local.aws_region}.amazoncognito.com/oauth2/token"
      user_info_endpoint     = "https://${var.cognito_domain}.auth.${local.aws_region}.amazoncognito.com/oauth2/userInfo"

      on_unauthenticated_request = "deny"
    }
  }

  action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.collector.arn
  }

  condition {
    path_pattern {
      values = ["/v1/metrics", "/v1/logs", "/v1/traces"]
    }
  }

  condition {
    http_header {
      http_header_name = "content-type"
      values           = ["application/x-protobuf", "application/json"]
    }
  }

  tags = var.tags
}

# -----------------------------------------------------------------------------
# WAF WebACL Association — always attached (WAF is created inline by the waf module)
# -----------------------------------------------------------------------------
resource "aws_wafv2_web_acl_association" "alb" {
  resource_arn = aws_lb.main.arn
  web_acl_arn  = var.waf_acl_arn
}
