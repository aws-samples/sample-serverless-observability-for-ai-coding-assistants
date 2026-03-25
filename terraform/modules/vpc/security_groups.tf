# -----------------------------------------------------------------------------
# Security Groups — Network access control per the design's Security Group Matrix
# Requirements: 9.3, 9.4, 9.5, 9.6, 9.7, 9.10
# -----------------------------------------------------------------------------

# --- sg-alb: Application Load Balancer ---
# Inbound: TCP 443 from 0.0.0.0/0 (public OTLP endpoint)
# Outbound: TCP 4318 (HTTP/protobuf), TCP 13133 (health) to sg-collector
resource "aws_security_group" "alb" {
  name        = "${var.project_name}-${var.environment}-sg-alb"
  description = "Security group for ALB - public OTLP ingestion endpoint"
  vpc_id      = aws_vpc.main.id

  tags = merge(var.tags, {
    Name = "${var.project_name}-${var.environment}-sg-alb"
  })
}

resource "aws_vpc_security_group_ingress_rule" "alb_https" {
  security_group_id = aws_security_group.alb.id
  description       = "Allow HTTPS/OTLP from internet"
  ip_protocol       = "tcp"
  from_port         = 443
  to_port           = 443
  cidr_ipv4         = "0.0.0.0/0"

  tags = merge(var.tags, {
    Name = "alb-inbound-https"
  })
}

resource "aws_vpc_security_group_egress_rule" "alb_to_collector_http" {
  security_group_id            = aws_security_group.alb.id
  description                  = "Allow HTTP/protobuf to OTel Collector"
  ip_protocol                  = "tcp"
  from_port                    = 4318
  to_port                      = 4318
  referenced_security_group_id = aws_security_group.collector.id

  tags = merge(var.tags, {
    Name = "alb-egress-http-to-collector"
  })
}

resource "aws_vpc_security_group_egress_rule" "alb_to_collector_health" {
  security_group_id            = aws_security_group.alb.id
  description                  = "Allow health check to OTel Collector"
  ip_protocol                  = "tcp"
  from_port                    = 13133
  to_port                      = 13133
  referenced_security_group_id = aws_security_group.collector.id

  tags = merge(var.tags, {
    Name = "alb-egress-health-to-collector"
  })
}

# --- sg-collector: OTel Collector (ECS Fargate) ---
# Inbound: TCP 4318 (HTTP/protobuf), TCP 13133 (health) from sg-alb
# Outbound: TCP 443 to sg-vpc-endpoints
resource "aws_security_group" "collector" {
  name        = "${var.project_name}-${var.environment}-sg-collector"
  description = "Security group for OTel Collector ECS tasks"
  vpc_id      = aws_vpc.main.id

  tags = merge(var.tags, {
    Name = "${var.project_name}-${var.environment}-sg-collector"
  })
}

resource "aws_vpc_security_group_ingress_rule" "collector_http" {
  security_group_id            = aws_security_group.collector.id
  description                  = "Allow HTTP/protobuf from ALB"
  ip_protocol                  = "tcp"
  from_port                    = 4318
  to_port                      = 4318
  referenced_security_group_id = aws_security_group.alb.id

  tags = merge(var.tags, {
    Name = "collector-inbound-http-from-alb"
  })
}

resource "aws_vpc_security_group_ingress_rule" "collector_health" {
  security_group_id            = aws_security_group.collector.id
  description                  = "Allow health check from ALB"
  ip_protocol                  = "tcp"
  from_port                    = 13133
  to_port                      = 13133
  referenced_security_group_id = aws_security_group.alb.id

  tags = merge(var.tags, {
    Name = "collector-inbound-health-from-alb"
  })
}

resource "aws_vpc_security_group_egress_rule" "collector_to_vpc_endpoints" {
  security_group_id = aws_security_group.collector.id
  description       = "Allow HTTPS outbound"
  ip_protocol       = "tcp"
  from_port         = 443
  to_port           = 443
  cidr_ipv4         = "0.0.0.0/0"

  tags = merge(var.tags, {
    Name = "collector-egress-https"
  })
}

# --- sg-grafana: Amazon Managed Grafana ---
# Inbound: TCP 443 from corporate CIDR / VPN
# Outbound: TCP 443 to sg-vpc-endpoints
resource "aws_security_group" "grafana" {
  name        = "${var.project_name}-${var.environment}-sg-grafana"
  description = "Security group for Managed Grafana workspace"
  vpc_id      = aws_vpc.main.id

  tags = merge(var.tags, {
    Name = "${var.project_name}-${var.environment}-sg-grafana"
  })
}

resource "aws_vpc_security_group_ingress_rule" "grafana_https" {
  count = length(var.corporate_cidr_blocks)

  security_group_id = aws_security_group.grafana.id
  description       = "Allow HTTPS from corporate network / VPN"
  ip_protocol       = "tcp"
  from_port         = 443
  to_port           = 443
  cidr_ipv4         = var.corporate_cidr_blocks[count.index]

  tags = merge(var.tags, {
    Name = "grafana-inbound-https-corporate-${count.index}"
  })
}

resource "aws_vpc_security_group_egress_rule" "grafana_to_vpc_endpoints" {
  security_group_id = aws_security_group.grafana.id
  description       = "Allow HTTPS outbound"
  ip_protocol       = "tcp"
  from_port         = 443
  to_port           = 443
  cidr_ipv4         = "0.0.0.0/0"

  tags = merge(var.tags, {
    Name = "grafana-egress-https"
  })
}

# --- sg-vpc-endpoints: VPC Interface Endpoints ---
# Inbound: TCP 443 from sg-collector and sg-grafana
# Outbound: managed by AWS (PrivateLink)
resource "aws_security_group" "vpc_endpoints" {
  name        = "${var.project_name}-${var.environment}-sg-vpc-endpoints"
  description = "Security group for VPC interface endpoints (PrivateLink)"
  vpc_id      = aws_vpc.main.id

  tags = merge(var.tags, {
    Name = "${var.project_name}-${var.environment}-sg-vpc-endpoints"
  })
}

resource "aws_vpc_security_group_ingress_rule" "vpc_endpoints_from_collector" {
  security_group_id            = aws_security_group.vpc_endpoints.id
  description                  = "Allow HTTPS from OTel Collector"
  ip_protocol                  = "tcp"
  from_port                    = 443
  to_port                      = 443
  referenced_security_group_id = aws_security_group.collector.id

  tags = merge(var.tags, {
    Name = "vpc-endpoints-inbound-from-collector"
  })
}

resource "aws_vpc_security_group_ingress_rule" "vpc_endpoints_from_grafana" {
  security_group_id            = aws_security_group.vpc_endpoints.id
  description                  = "Allow HTTPS from Grafana"
  ip_protocol                  = "tcp"
  from_port                    = 443
  to_port                      = 443
  referenced_security_group_id = aws_security_group.grafana.id

  tags = merge(var.tags, {
    Name = "vpc-endpoints-inbound-from-grafana"
  })
}
