# Serverless Observability for AI Coding Assistants — Deployment Guide

## Architecture

```text
Claude Code / Codex CLI (developer laptops)
    |
    |  OTLP/HTTP (protobuf) + Bearer Token
    v
+---------------------------+
|  ALB (HTTPS, port 443)    |---- WAF (rate limiting + managed rules)
|  Allowed CIDRs only       |
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
- `otlp_allowed_cidr_blocks` — **required.** Public IPv4 CIDRs allowed to reach the OTLP endpoint (ALB, TCP 443): the egress ranges your developers' machines use, such as your corporate NAT or VPN. Find a machine's egress IP with `curl https://checkip.amazonaws.com`. `0.0.0.0/0` opens the endpoint to the whole internet, leaving the shared bearer token as the only control; `terraform plan` warns if you use it.
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

- `otlp_endpoint_url` — ALB endpoint for Claude Code and Codex clients
- `ecr_repository_url` — push collector Docker image here
- `grafana_workspace_url` — Grafana UI URL
- `archive_bucket_name` — S3 bucket for telemetry data
- `athena_workgroup` — Athena workgroup for queries
- `self_signed_certificate_pem` — the ALB's self-signed certificate (empty when `acm_certificate_arn` is set). Clients trust this file instead of disabling certificate validation. Save it and distribute it with the endpoint URL:

```bash
terraform output -raw self_signed_certificate_pem > alb-cert.pem
```

The certificate names the ALB's DNS name, so TLS clients can verify it. If you upgrade a deployment created before this change, `terraform apply` reissues the certificate in place (same ACM ARN); download `alb-cert.pem` again afterwards. The upgrade also replaces the ALB's HTTPS ingress rule with one rule per entry in `otlp_allowed_cidr_blocks`.

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

Run these from a network in `otlp_allowed_cidr_blocks`. `--cacert` makes curl verify the ALB's certificate.

Without the token (expect `401`):

```bash
curl --cacert alb-cert.pem -s -o /dev/null -w '%{http_code}\n' \
  -X POST <otlp_endpoint_url>/v1/logs \
  -H "Content-Type: application/json" -d '{"resourceLogs":[]}'
```

With the token (expect `200`):

```bash
curl --cacert alb-cert.pem -s -o /dev/null -w '%{http_code}\n' \
  -X POST <otlp_endpoint_url>/v1/logs \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer <telemetry_api_key>" -d '{"resourceLogs":[]}'
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
    "NODE_EXTRA_CA_CERTS": "/absolute/path/to/alb-cert.pem"
  }
}
```

Replace `<otlp_endpoint_url>` and `<telemetry_api_key>` with your deployment values, and the path with where you saved `alb-cert.pem`.

`NODE_EXTRA_CA_CERTS` makes Claude Code trust the deployment's self-signed certificate while keeping certificate validation on. With an ACM certificate (`acm_certificate_arn`), leave it out. Don't use `NODE_TLS_REJECT_UNAUTHORIZED=0`: it turns off certificate validation for every connection the Claude Code process makes, including its model API calls.

Claude Code ignores OpenTelemetry exporter variables in a repository's `.claude/settings.json`; set them in `~/.claude/settings.json`, your shell, or managed settings. If your organization configures OpenTelemetry for Claude Code through managed settings, that destination is locked and Claude Code drops developer-set OTLP variables; ask your administrator to add this endpoint there. See [Claude Code monitoring](https://docs.anthropic.com/en/docs/claude-code/monitoring-usage).

Data appears in S3 within ~5 minutes (Firehose buffer). Dashboards update on next refresh.

## Step 10: Configure Codex CLI Clients

Codex reads its OpenTelemetry settings from the `[otel]` table of the user-level `~/.codex/config.toml` (`$CODEX_HOME/config.toml`); an `[otel]` table in a project's `.codex/config.toml` is ignored. Add the following (also in `scripts/codex-otel-config.toml`):

```toml
[otel]
environment = "dev"
log_user_prompt = false   # true stores prompt text in the prompt column
exporter = { otlp-http = { endpoint = "<otlp_endpoint_url>/v1/logs", protocol = "binary", tls = { ca-certificate = "/absolute/path/to/alb-cert.pem" } } }
metrics_exporter = { otlp-http = { endpoint = "<otlp_endpoint_url>/v1/metrics", protocol = "binary", tls = { ca-certificate = "/absolute/path/to/alb-cert.pem" } } }
trace_exporter = "none"   # the collector has no traces pipeline

[shell_environment_policy]
exclude = ["OTEL_*"]      # keep the bearer token out of the commands Codex runs
```

Then, in the environment Codex runs in:

```bash
export OTEL_EXPORTER_OTLP_HEADERS="Authorization=Bearer <telemetry_api_key>"
```

- Codex uses each endpoint exactly as written, so include the `/v1/logs` and `/v1/metrics` paths. `protocol` is required.
- Codex doesn't expand `${VAR}` references in `config.toml`; the exporter reads the token from `OTEL_EXPORTER_OTLP_HEADERS`.
- Set `metrics_exporter` explicitly. Left unset, Codex sends its metrics to OpenAI rather than to this endpoint; `"none"` sends no metrics.
- Don't set `OTEL_EXPORTER_OTLP_COMPRESSION` for Codex. In testing with Codex CLI 0.164 it stopped the exporter from starting, so nothing was sent.
- `codex exec` hides exporter errors. Set `RUST_LOG=opentelemetry_otlp=debug,opentelemetry_sdk=info` to see TLS, `401` and `403` failures.
- With an ACM certificate, drop the `tls` tables.

**What lands where.** Codex events go to the `logs` table with `event_name` values such as `codex.user_prompt`, `codex.api_request`, `codex.sse_event`, `codex.tool_decision` and `codex.tool_result`; `service_name` is `codex_exec` for `codex exec`. Columns whose names match Claude Code's are filled: `event_name`, `event_timestamp`, `model`, `terminal_type`, `prompt` (with `log_user_prompt = true`), `tool_name`, `decision` and `duration_ms`. Codex reports its conversation ID and token counts under other attribute names, so `session_id` and the token columns stay empty for Codex rows. Codex CLI 0.164 sends no cost and no per-person ID, so `cost_usd` and `user_id` stay empty too. Most Codex metrics are histograms, which the flatten Lambda stores with `metric_value = 0`.

The Grafana dashboards have no Codex panels. Query Codex data in Athena:

```sql
-- Codex events for one day; adjust the date
SELECT event_name, count(*) AS events
FROM claude_code_telemetry_dev.logs
WHERE year = 2026 AND month = 10 AND day = 27
  AND service_name LIKE 'codex%'
GROUP BY event_name
ORDER BY events DESC;
```

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

### Requests time out

The ALB security group only admits `otlp_allowed_cidr_blocks`. Check the client's egress IP with `curl https://checkip.amazonaws.com` and add its range.

### TLS errors (`certificate verify failed`, `hostname mismatch`, `self-signed certificate`)

- Point the client at `alb-cert.pem` from `terraform output -raw self_signed_certificate_pem` (Claude Code: `NODE_EXTRA_CA_CERTS`; Codex: `tls.ca-certificate`; curl: `--cacert`).
- Connect with the ALB DNS name in `otlp_endpoint_url`; that's the name the certificate carries.
- Deployments created before the certificate named the ALB have one that carries only `CN=telemetry.dev.internal`, which current TLS clients reject. Run `terraform apply` to reissue it, then save `alb-cert.pem` again.

### 403 Forbidden

The WAF rejected the request. Find the rule in its sampled requests:

```bash
aws wafv2 get-sampled-requests --scope REGIONAL --region us-east-1 \
  --web-acl-arn <web_acl_arn> \
  --rule-metric-name claude-code-telemetry-common-rules-dev \
  --time-window StartTime=<epoch_seconds>,EndTime=<epoch_seconds> \
  --max-items 100
```

- `NoUserAgent_HEADER`: the request had no `User-Agent` header (custom clients and proxies).
- `rate-limit-per-ip` (rule metric `claude-code-telemetry-rate-limit-dev`): more than 2000 requests in 5 minutes from one IP.
- `SizeRestrictions_BODY` only counts here, so bodies over 8 KB are recorded, not blocked. On a deployment of the WAF module from before this change it blocks, which drops most Claude Code and Codex export batches.

### Claude Code sends nothing

Start it with `claude --debug-file /tmp/claude-debug.log` and look for `[3P telemetry]` errors. Exporter variables in a repository's `.claude/settings.json` are ignored, and managed settings can lock the destination (see Step 9).
