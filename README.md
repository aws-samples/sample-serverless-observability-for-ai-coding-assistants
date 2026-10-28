# Serverless Observability for AI Coding Assistants

An AWS-based observability platform for collecting, storing, and visualizing OpenTelemetry telemetry from AI coding assistants — [Claude Code](https://docs.anthropic.com/en/docs/claude-code/monitoring-usage) and the [OpenAI Codex CLI](https://developers.openai.com/codex/config-advanced). Built with Terraform, it deploys an OpenTelemetry Collector on ECS Fargate behind an ALB, with both metrics and logs flowing through Kinesis Data Streams → Firehose (with a Lambda flatten transform) → S3 as Parquet. All data is queryable via Amazon Athena and visualized through Amazon Managed Grafana with the Athena data source.

> **Client coverage:** the Glue schema was built around Claude Code's event and attribute names. Codex events land in the same `logs` table, and the flatten Lambda copies Codex's conversation, token, status-code and error attributes onto the same columns. Codex CLI 0.164 sends no cost and no per-person ID, so `cost_usd` and `user_id` stay empty for Codex rows. The Grafana dashboards have no Codex panels; query Codex data in Athena. See [Codex CLI](#codex-cli).
>
> AWS resource names keep the `claude-code-telemetry` prefix (the `project_name` default) so existing deployments are not replaced.

## Architecture

```text
Claude Code / Codex CLI clients
    │  OTLP/HTTP + Bearer Token
    ▼
┌─────────────────────┐
│  ALB + WAF          │  (public subnet, allowed client CIDRs only)
└────────┬────────────┘
         ▼
┌─────────────────────┐
│  ECS Fargate        │  (private subnet, VPC endpoints)
│  OTel Collector     │
└───┬─────────────┬───┘
    │             │
    ▼             ▼
┌─────────┐  ┌─────────┐
│ Kinesis  │  │ Kinesis  │
│ metrics  │  │ logs     │
└────┬─────┘  └────┬────┘
     │             │
     ▼             ▼
┌──────────────────────────┐
│  Firehose (2 streams)    │
│  Lambda flatten transform│
│  JSON → Parquet (Snappy) │
└────────────┬─────────────┘
             ▼
┌──────────────────────────┐
│  S3 Telemetry Archive    │
│  metrics/ + logs/        │
│  Flat-column Parquet     │
└────────────┬─────────────┘
             ▼
┌──────────────────────────┐
│  Glue Catalog + Athena   │
└────────────┬─────────────┘
             ▼
┌──────────────────────────┐
│  Amazon Managed Grafana  │
│  (Athena data source)    │
└──────────────────────────┘
```

See [docs/architecture.drawio](docs/architecture.drawio) for the full diagram.

> **Scope:** This platform is architected for single AWS account usage. Multi-account deployments would require architectural changes for tenant segregation, cross-account IAM roles, data isolation, and separate pipeline partitioning.

## Project Structure

```text
├── terraform/              # Infrastructure as Code
│   ├── main.tf             # Root module — all components + root-level resources
│   ├── variables.tf        # Input variables
│   ├── outputs.tf          # Stack outputs
│   ├── providers.tf        # AWS provider config
│   ├── backend.tf          # State backend (local for PoC)
│   ├── terraform.tfvars.example
│   ├── modules/
│   │   ├── alb/            # Application Load Balancer
│   │   ├── ecs-collector/  # ECS Fargate OTel Collector
│   │   ├── grafana/        # Amazon Managed Grafana
│   │   ├── iam/            # IAM roles and policies
│   │   ├── vpc/            # VPC, subnets, NAT gateway, VPC endpoints, SGs
│   │   └── waf/            # WAF rate limiting
│   ├── collector/          # OTel Collector Docker image
│   │   ├── Dockerfile
│   │   └── otel-collector-config.yaml
│   ├── lambda/             # Firehose transform function
│   │   └── flatten.py      # Flattens nested OTLP JSON → flat columns
│   └── dashboards/         # Grafana dashboard JSON definitions
│       ├── developer-dashboard.json
│       ├── organization-dashboard.json
│       └── telemetry-dashboard.json
├── scripts/                # Operational scripts
│   ├── deploy-dashboards.sh
│   ├── setup-grafana.sh
│   ├── verify-dashboards.py
│   ├── test-settings.json
│   ├── full-telemetry-settings.json
│   └── codex-otel-config.toml
└── docs/                   # Documentation
    ├── DEPLOYMENT.md
    ├── THREAT-MODEL.md
    ├── VULNERABILITIES.md
    └── architecture.drawio
```

Root-level resources in `main.tf` (not in modules): S3 bucket, Kinesis streams (2), Firehose delivery streams (2), Firehose IAM role, Lambda flatten function, Glue catalog database + tables, Athena workgroup.

## Prerequisites

- AWS CLI v2 with admin credentials
- Terraform >= 1.5
- Docker (for building the OTel Collector image)
- Python 3 (for dashboard scripts)
- AWS IAM Identity Center (SSO) enabled in the target account (required for Managed Grafana)

## Quick Start

```bash
# 1. Configure
cd terraform
cp terraform.tfvars.example terraform.tfvars
# Edit terraform.tfvars with your values (otlp_allowed_cidr_blocks is required)

# 2. Deploy infrastructure, then save the ALB certificate clients will trust
terraform init
terraform apply
terraform output -raw self_signed_certificate_pem > alb-cert.pem

# 3. Build and push the collector image
cd collector
docker build --platform linux/amd64 -t <ecr_repository_url>:latest .
docker push <ecr_repository_url>:latest

# 4. Force ECS redeployment
aws ecs update-service \
  --cluster claude-code-telemetry-cluster-dev \
  --service claude-code-telemetry-collector-dev \
  --force-new-deployment

# 5. Configure Grafana Athena data source + deploy dashboards
cd ../../scripts
./deploy-dashboards.sh <grafana_url> <api_key>
```

See [docs/DEPLOYMENT.md](docs/DEPLOYMENT.md) for the full walkthrough.

## Client Configuration

Clients connect to `<otlp_endpoint_url>` from a network listed in `otlp_allowed_cidr_blocks`, send the bearer token, and trust `alb-cert.pem` (step 2 above). With an ACM certificate (`acm_certificate_arn`), skip the certificate setting.

### Claude Code

```bash
export CLAUDE_CODE_ENABLE_TELEMETRY=1
export OTEL_METRICS_EXPORTER=otlp
export OTEL_LOGS_EXPORTER=otlp
export OTEL_EXPORTER_OTLP_PROTOCOL=http/protobuf
export OTEL_EXPORTER_OTLP_ENDPOINT=<otlp_endpoint_url>
export OTEL_EXPORTER_OTLP_HEADERS="Authorization=Bearer <telemetry_api_key>"
export NODE_EXTRA_CA_CERTS=/absolute/path/to/alb-cert.pem
```

Pre-built settings files: `scripts/test-settings.json` and `scripts/full-telemetry-settings.json`.

### Codex CLI

Add to `~/.codex/config.toml` (see `scripts/codex-otel-config.toml`), and export `OTEL_EXPORTER_OTLP_HEADERS="Authorization=Bearer <telemetry_api_key>"` where Codex runs:

```toml
[otel]
environment = "dev"
exporter = { otlp-http = { endpoint = "<otlp_endpoint_url>/v1/logs", protocol = "binary", tls = { ca-certificate = "/absolute/path/to/alb-cert.pem" } } }
metrics_exporter = { otlp-http = { endpoint = "<otlp_endpoint_url>/v1/metrics", protocol = "binary", tls = { ca-certificate = "/absolute/path/to/alb-cert.pem" } } }
trace_exporter = "none"
```

Details, limits and troubleshooting: [docs/DEPLOYMENT.md](docs/DEPLOYMENT.md#step-10-configure-codex-cli-clients).

## Known Limitations & Production Readiness

This is a **PoC deployment**. The following HIGH-severity issues must be resolved before production use:

| ID       | Issue                                                      | Priority |
| -------- | ---------------------------------------------------------- | -------- |
| VULN-001 | Shared static bearer token — no per-user identity          | P1       |
| VULN-002 | No PII/secret redaction in telemetry pipeline              | P1       |
| VULN-003 | Self-signed TLS (clients must trust the certificate file)  | P1       |
| VULN-007 | No CloudTrail audit logging                                | P1       |
| VULN-012 | Unmasked prompts stored in S3 Parquet                      | P1       |
| VULN-004 | Data volume flood / cost bomb                              | P2       |
| VULN-013 | Lambda function code tampering (no code signing)           | P2       |
| VULN-016 | No ALB-layer OIDC auth without ACM certificate (mitigated) | P1       |

Recently fixed: VULN-014 (Lambda key injection/field overwrite), VULN-015 (gRPC OIDC bypass), VULN-017 (OTLP endpoint open to the whole internet). VULN-003 is mitigated: the self-signed certificate now names the ALB, so clients verify it instead of disabling validation.

Full vulnerability register: [docs/VULNERABILITIES.md](docs/VULNERABILITIES.md)
Threat model: [docs/THREAT-MODEL.md](docs/THREAT-MODEL.md)

## Security

Note: this asset represents a proof-of-value for the services included and is not intended as a production-ready solution. You must determine how the AWS Shared Responsibility applies to their specific use case and implement the needed controls to achieve their desired security outcomes. AWS offers a broad set of security tools and configurations to enable our customers.

Ultimately it is your responsibility as the developer of a full stack application to ensure all of its aspects are secure. We provide security best practices in repository documentation and provide a secure baseline but Amazon holds no responsibility for the security of applications built from this tool.

## License

This project is licensed under the MIT-0 License.
