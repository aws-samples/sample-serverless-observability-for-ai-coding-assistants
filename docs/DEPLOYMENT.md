# Claude Code Telemetry Platform — Deployment Guide

## Architecture

```text
Claude Code (developer laptops)
    |
    |  OTLP/HTTP (protobuf) + Bearer Token
    v
+---------------------------+
|  ALB (HTTPS, port 443)    |---- WAF (rate limiting + managed rules)
|  Self-signed TLS (PoC)    |
+------------+--------------+
             |  (public subnet)
             v
+---------------------------------------------+
|  ECS Fargate -- OTel Collector (2 tasks)    |
|  otel-collector-contrib:latest              |  (private subnet)
|  Bearer token auth (bearertokenauth ext)    |
|                                             |
|  Pipelines:                                 |
|    metrics -> Kinesis Data Stream            |
|    logs    -> Kinesis Data Stream            |
+------+------------------------------+------+
       |                               |
       v                               v
+---------------------------------------------+
|  Kinesis Data Streams (2 streams)           |
|  metrics + logs                             |
+---------------------+-----------------------+
                      |
                      v
+---------------------------------------------+
|  Kinesis Firehose (2 delivery streams)      |
|  Lambda flatten transform (OTLP → flat JSON)|
|  JSON → Parquet conversion (Snappy)         |
|  Partitioned by year/month/day              |
+---------------------+-----------------------+
                      |
                      v
+---------------------------------------------+
|  S3 Telemetry Archive (Parquet)             |
|  metrics/ + logs/ (flat columns)            |
|  Encrypted (AES-256), Versioned             |
|  Lifecycle: Glacier 90d, Expire 365d        |
+---------------------+-----------------------+
                      |
                      v
+---------------------------------------------+
|  Glue Data Catalog + Amazon Athena          |
|  Partition projection (zero-cost discovery) |
|  SQL queries directly on flat Parquet data  |
+---------------------+-----------------------+
                      |
                      v
+---------------------------------------------+
|  Amazon Managed Grafana                     |
|  Athena data source (via NAT gateway)       |
|  3 dashboards: Developer, Org, Telemetry    |
+---------------------------------------------+
```

---

## Prerequisites

- AWS CLI v2 with admin credentials
- Docker (for building the OTel Collector image)
- Terraform >= 1.5
- Python 3 (for dashboard scripts)
- AWS IAM Identity Center (SSO) enabled in the account, OR SAML configured (SAML is the default)

---

## Step 1: Configure Variables

```bash
cd terraform
cp terraform.tfvars.example terraform.tfvars
```

Edit `terraform.tfvars`:

- `corporate_cidr_blocks` — your network CIDRs for Grafana access
- `telemetry_api_key` — a strong random string for client authentication
- `grafana_auth_provider` — `"SAML"` (default) or `"AWS_SSO"` if IAM Identity Center is enabled
- `grafana_workspace_name` — optional override to avoid 409 errors on workspace re-creation
- `acm_certificate_arn` — (production) ACM certificate ARN for HTTPS. **Required for OIDC authentication.** Without this, the ALB uses a self-signed cert and forwards all traffic without identity checks — only the bearer token at the collector provides auth.
- `cognito_user_pool_id` — (production) Cognito user pool for OIDC. Only effective when `acm_certificate_arn` is also set.

## Step 2: Deploy Infrastructure

```bash
terraform init
terraform apply
```

Note these outputs:

- `otlp_endpoint_url` — ALB endpoint for Claude Code clients
- `ecr_repository_url` — push collector Docker image here
- `grafana_workspace_url` — Grafana UI URL
- `archive_bucket_name` — S3 bucket for telemetry data
- `athena_workgroup` — Athena workgroup for queries

## Step 3: Build and Push OTel Collector

```bash
cd terraform/collector

docker build --platform linux/amd64 \
  -t <ecr_repository_url>:latest .

aws ecr get-login-password --region us-east-1 \
  | docker login --username AWS --password-stdin \
    <account_id>.dkr.ecr.us-east-1.amazonaws.com

docker push <ecr_repository_url>:latest
```

## Step 4: Deploy Collector to ECS

```bash
aws ecs update-service \
  --cluster claude-code-telemetry-cluster-dev \
  --service claude-code-telemetry-collector-dev \
  --force-new-deployment \
  --region us-east-1
```

Wait ~2 minutes, then verify:

```bash
aws ecs describe-services \
  --cluster claude-code-telemetry-cluster-dev \
  --services claude-code-telemetry-collector-dev \
  --region us-east-1 \
  --query 'services[0].{desired:desiredCount,running:runningCount}'
```

Expected: `desired: 2, running: 2`

## Step 5: Configure Grafana Athena Data Source

1. Open the Grafana workspace URL
2. Go to Connections → Data Sources → Add data source → Athena
3. Configure:
   - Authentication: `Workspace IAM Role`
   - Default Region: `us-east-1`
   - Catalog: `AwsDataCatalog`
   - Database: `claude_code_telemetry_dev`
   - Workgroup: `claude-code-telemetry-dev`
4. Click "Save & Test" — should say "Data source is working"

Note: The Lambda flatten function automatically converts nested OTLP JSON into flat-column records before Parquet conversion. No Athena views are needed — query the `logs` and `metrics` tables directly.

## Step 6: Create Grafana API Key

```bash
aws grafana create-workspace-api-key \
  --workspace-id <workspace-id> \
  --key-name "admin-key" \
  --key-role ADMIN \
  --seconds-to-live 2592000 \
  --region us-east-1
```

Save the `key` from the response — it is only shown once.

## Step 7: Deploy Dashboards

```bash
cd scripts
./deploy-dashboards.sh <grafana_url> <api_key> <athena_database>
```

The third argument is the Glue database name — matches the environment you deployed (e.g. `claude_code_telemetry_dev`, `claude_code_telemetry_staging`, `claude_code_telemetry_prod`). Defaults to `claude_code_telemetry_dev` if omitted.

## Step 8: Verify Authentication

Test unauthenticated (should be rejected):

```bash
curl -k -X POST <otlp_endpoint_url>/v1/metrics \
  -H "Content-Type: application/x-protobuf" -d "test"
```

Test authenticated (should pass):

```bash
curl -k -X POST <otlp_endpoint_url>/v1/metrics \
  -H "Content-Type: application/x-protobuf" \
  -H "Authorization: Bearer <telemetry_api_key>" -d "test"
```

## Step 9: Configure Claude Code Clients

Claude Code reads telemetry configuration from `~/.claude/settings.json` (not shell environment variables). Add the following to the `env` block:

```json
{
  "env": {
    "CLAUDE_CODE_ENABLE_TELEMETRY": "1",
    "OTEL_METRICS_EXPORTER": "otlp",
    "OTEL_LOGS_EXPORTER": "otlp",
    "OTEL_EXPORTER_OTLP_PROTOCOL": "http/protobuf",
    "OTEL_EXPORTER_OTLP_ENDPOINT": "<otlp_endpoint_url>",
    "OTEL_EXPORTER_OTLP_HEADERS": "Authorization=Bearer <telemetry_api_key>",
    "OTEL_METRIC_EXPORT_INTERVAL": "10000",
    "OTEL_LOGS_EXPORT_INTERVAL": "5000",
    "OTEL_LOG_USER_PROMPTS": "1",
    "OTEL_LOG_TOOL_DETAILS": "1",
    "NODE_TLS_REJECT_UNAUTHORIZED": "0"
  }
}
```

Replace `<otlp_endpoint_url>` and `<telemetry_api_key>` with your deployment values.

Set `NODE_TLS_REJECT_UNAUTHORIZED=0` only for self-signed TLS (PoC). Use a proper ACM certificate in production.

Data appears in S3 within ~5 minutes (Firehose buffer). Dashboards update on next refresh.

---

## Verify Data Pipeline

Check S3 for data:

```bash
aws s3 ls s3://<archive_bucket_name>/metrics/ --recursive
aws s3 ls s3://<archive_bucket_name>/logs/ --recursive
```

Test Athena query (queries the flat logs table directly):

```bash
aws athena start-query-execution \
  --query-string "SELECT event_name, count(*) FROM claude_code_telemetry_dev.logs GROUP BY event_name" \
  --work-group claude-code-telemetry-dev \
  --region us-east-1
```

---

## Lambda Flatten Function

The Lambda function (`terraform/lambda/flatten.py`) is invoked by Firehose as a processing transform. It:

1. Receives base64-encoded OTLP JSON records from Firehose
2. Extracts nested resource attributes, scope attributes, and log/metric attributes
3. Flattens them into flat key-value records (one record per log entry or metric data point)
4. Returns flat JSON that Firehose converts to Parquet using the Glue table schema

This eliminates the need for complex Athena views or `UNNEST` queries — the `logs` and `metrics` tables have flat columns like `event_name`, `user_id`, `cost_usd`, `prompt`, etc.

---

## Updating the OTel Collector

After editing `terraform/collector/otel-collector-config.yaml`:

```bash
cd terraform/collector
docker build --platform linux/amd64 -t <ecr_repository_url>:latest .
docker push <ecr_repository_url>:latest
aws ecs update-service \
  --cluster claude-code-telemetry-cluster-dev \
  --service claude-code-telemetry-collector-dev \
  --force-new-deployment --region us-east-1
```

## Teardown

```bash
cd terraform
terraform destroy
```

All resources have `force_destroy = true` for PoC.

---

## Troubleshooting

### No data in S3

- Verify collector is running: `desired: 2, running: 2`
- Check collector logs for Kinesis errors: `aws logs tail /ecs/claude-code-telemetry-collector-dev`
- Verify Kinesis streams are receiving data: check CloudWatch metrics for `IncomingRecords`
- Verify Firehose delivery streams are active (not in error state)
- Check Firehose error logs: `aws logs tail /aws/firehose/claude-code-telemetry-dev-metrics`
- Check Lambda flatten function logs for processing errors
- Wait 5 minutes (Firehose buffer interval)

### Athena queries return 0 rows

- Check partition projection digits match S3 paths (month/day must be zero-padded)
- Verify S3 has Parquet files in the expected partition paths
- Check that the Lambda flatten function is producing records (not all `ProcessingFailed`)
- Preview a Parquet file to confirm column names match the Glue table schema

### Grafana Athena data source timeout

- Verify NAT gateway exists (Grafana reaches Athena API via internet through NAT)
- Check Grafana SG allows outbound HTTPS
- Verify Grafana IAM role has Athena, Glue, and S3 permissions

### ECS tasks stuck in PENDING

- Check for GuardDuty sidecar pull failures (account-level setting)
- Verify ECR VPC endpoint is available
- Check execution role has ECR pull permissions

### Client gets "missing or empty authorization header"

```bash
export OTEL_EXPORTER_OTLP_HEADERS="Authorization=Bearer <telemetry_api_key>"
```

The value must match `telemetry_api_key` in `terraform.tfvars`.
