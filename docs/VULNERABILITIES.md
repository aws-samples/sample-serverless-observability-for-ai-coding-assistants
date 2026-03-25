# Vulnerability Register — Claude Code Telemetry Platform

**Scope:** PoC deployment (dev environment)
**Date:** March 2026
**Derived from:** [THREAT-MODEL.md](THREAT-MODEL.md)

---

## Severity Definitions

| Severity       | Definition                                                                     |
| -------------- | ------------------------------------------------------------------------------ |
| CRITICAL       | Exploitable now, leads to data breach or full system compromise                |
| HIGH           | Exploitable with minimal effort, significant data exposure or integrity impact |
| MEDIUM         | Requires specific conditions, moderate impact                                  |
| LOW            | Minimal impact or requires significant access to exploit                       |
| ACCEPTED (PoC) | Known risk, explicitly accepted for PoC, must fix before production            |

---

## HIGH Vulnerabilities

### VULN-001: Shared Static Bearer Token — No Per-User Identity

- **Threat IDs:** S1, S2, S3, R1
- **Files:** `terraform/terraform.tfvars`, `terraform/modules/ecs-collector/main.tf`, `terraform/collector/otel-collector-config.yaml`
- **Description:** All Claude Code clients share a single static bearer token. No expiry, no rotation, no per-user binding. Any client can submit telemetry as any user_id or org_id.
- **Impact:** Cannot attribute telemetry to a specific developer. Token compromise grants permanent write access. Dashboard integrity depends on client honesty.
- **Remediation:**
  1. Implement OIDC JWT validation (e.g., Cognito)
  2. Extract user identity from JWT claims server-side
  3. Validate org_id/user_id against token claims in the collector
  4. Implement token rotation
- **Status:** OPEN (accepted for PoC)

### VULN-002: No PII/Secret Redaction in Telemetry Pipeline — REOPENED

- **Threat IDs:** D1, D5
- **Components:** Kinesis → Firehose → Lambda → S3
- **Description:** There is no PII or secret redaction anywhere in the data pipeline. The previous CloudWatch data protection policy was removed when CloudWatch Logs was removed from the data path. User prompts — which may contain code, credentials, API keys, and personal information — are stored unmasked in S3 Parquet files.
- **Impact:** Anyone with S3 read access or Athena query permissions can read full prompt text. Secrets embedded in prompts are persisted to disk. Data subject access/deletion requests cannot be easily fulfilled.
- **Remediation:**
  1. Add redaction logic to the Lambda flatten function (regex-based masking of common secret patterns)
  2. Implement a dedicated PII detection service (e.g., Comprehend) in the Lambda transform
  3. Consider S3 Object Lock or bucket policies to restrict direct S3 access
  4. Add Athena query logging to track who queries prompt data
- **Status:** OPEN — HIGH priority (regression from previous CloudWatch-based architecture)

### VULN-003: Self-Signed TLS with Disabled Certificate Validation

- **Threat ID:** T1
- **Files:** `terraform/modules/alb/main.tf`, `docs/DEPLOYMENT.md`
- **Description:** The ALB uses a self-signed TLS certificate. Clients must set `NODE_TLS_REJECT_UNAUTHORIZED=0`, which disables ALL TLS certificate validation for the entire Node.js process.
- **Impact:** MITM attack on the same network can intercept the bearer token and all telemetry including prompts.
- **Remediation:**
  1. Obtain a proper ACM certificate for a custom domain
  2. Remove NODE_TLS_REJECT_UNAUTHORIZED=0 from all client configurations
- **Status:** OPEN (accepted for PoC)

### VULN-004: Data Volume Flood (Cost Bomb)

- **Threat IDs:** DoS2, T2
- **Components:** Kinesis Data Streams, Firehose, Lambda, S3, Athena
- **Description:** An attacker with a valid bearer token can flood the pipeline with arbitrary telemetry data. Unlike the previous AMP architecture (where the risk was cardinality explosion), the current architecture has cost exposure across multiple services: Kinesis shard hours and PUT records, Firehose ingestion volume, Lambda invocations, S3 storage, and Athena query scan bytes.
- **Impact:** Unbounded cost increase across the entire pipeline. Dashboard corruption with fake data. Increased Athena query costs as data volume grows.
- **Remediation:**
  1. Add `filter` processor in OTel collector to validate/allowlist payload fields
  2. Set Kinesis stream throughput limits and CloudWatch alarms on IncomingRecords
  3. Add S3 bucket size alarms
  4. Set Athena workgroup byte-scan limits (already configured at 10 GB)
  5. Add WAF request body size limits
- **Status:** OPEN

### VULN-012: S3 Parquet Contains Unmasked Prompts

- **Threat ID:** D5
- **Components:** S3 telemetry archive, Athena
- **Description:** The S3 bucket stores all telemetry data including full user prompts in Parquet format with no masking or encryption beyond AES-256 (AWS-managed keys). The `prompt` column in the logs table contains raw prompt text.
- **Impact:** Any principal with `s3:GetObject` on the bucket or `athena:StartQueryExecution` with the workgroup can read all prompts. Data persists for up to 365 days (lifecycle policy). Glacier transition at 90 days does not delete the data.
- **Remediation:**
  1. Implement field-level encryption for the `prompt` column before S3 write
  2. Use customer-managed KMS keys with key policy restricting decrypt access
  3. Add S3 bucket policy restricting read access to specific roles
  4. Implement Athena query result encryption with CMK
- **Status:** OPEN — HIGH priority

### VULN-013: Lambda Flatten Function Code Tampering

- **Threat ID:** T5
- **Components:** Lambda function (`terraform/lambda/flatten.py`)
- **Description:** The Lambda function that transforms OTLP JSON into flat records is a new attack surface. An attacker with `lambda:UpdateFunctionCode` permissions could modify the function to: drop security-relevant fields, inject false data, exfiltrate records to an external endpoint, or silently corrupt the data pipeline.
- **Impact:** Data integrity compromise. Potential data exfiltration. Silent pipeline corruption that may go undetected.
- **Remediation:**
  1. Enable Lambda code signing to prevent unauthorized code changes
  2. Restrict `lambda:UpdateFunctionCode` to CI/CD pipeline role only
  3. Add CloudTrail monitoring for Lambda API calls
  4. Implement Lambda function hash verification in deployment pipeline
- **Status:** OPEN

---

## MEDIUM Vulnerabilities

### VULN-005: Bearer Token Exposed in ECS Task Definition

- **Threat ID:** D3
- **File:** `terraform/modules/ecs-collector/main.tf`
- **Description:** `TELEMETRY_API_KEY` is a plaintext environment variable in the ECS task definition. Visible to anyone with `ecs:DescribeTaskDefinition` permissions.
- **Remediation:**
  1. Store the token in AWS Secrets Manager
  2. Reference via `secrets` block in the container definition
- **Status:** OPEN

### VULN-006: Bearer Token in Plaintext Terraform State

- **Threat ID:** D2
- **File:** `terraform/terraform.tfstate`
- **Description:** The `telemetry_api_key` is stored in plaintext in the local Terraform state file. `.gitignore` prevents committing, but the file exists on disk.
- **Remediation:**
  1. Migrate to S3 backend with encryption (backend.tf has this commented out)
  2. Enable DynamoDB state locking
  3. Delete local state file after migration
- **Status:** OPEN

### VULN-007: No CloudTrail Audit Logging

- **Threat ID:** R2
- **Description:** CloudTrail is disabled for the PoC. No audit trail for AWS API calls.
- **Impact:** Cannot investigate security incidents or detect unauthorized changes to Lambda, S3, Kinesis, or IAM.
- **Remediation:**
  1. Enable CloudTrail with S3 delivery
  2. Add EventBridge rules for security-relevant events (Lambda updates, S3 policy changes, IAM changes)
- **Status:** OPEN (accepted for PoC)

### VULN-008: No Grafana Row-Level Security

- **Threat ID:** D4
- **Component:** Grafana dashboards
- **Description:** All Grafana users can see all users' metrics, costs, prompts, and session data.
- **Remediation:**
  1. Implement Grafana team-based access with dashboard permissions
  2. Use variable injection from SAML/SSO claims to filter queries by user/org
- **Status:** OPEN (accepted for PoC)

---

## LOW Vulnerabilities

### VULN-009: ALB Deletion Protection Disabled

- **Threat ID:** DoS3
- **File:** `terraform/modules/alb/main.tf`
- **Description:** `enable_deletion_protection = false`. Accidental terraform destroy removes the ingestion endpoint.
- **Remediation:** Set to `true` for production.
- **Status:** OPEN (accepted for PoC)

### VULN-010: ECR Image Tag Mutability

- **File:** `terraform/modules/ecs-collector/main.tf`
- **Description:** `image_tag_mutability = "MUTABLE"`. The `:latest` tag can be overwritten.
- **Remediation:** Set to `IMMUTABLE` and use versioned tags in production.
- **Status:** OPEN (accepted for PoC)

### VULN-011: No Encryption with Customer-Managed Keys

- **Components:** S3, Kinesis Data Streams
- **Description:** All encryption uses AWS-managed keys. S3 uses AES-256, Kinesis uses default encryption. No customer-managed KMS CMKs. This means AWS operators theoretically have access to decryption keys.
- **Remediation:** Create KMS CMKs for S3 and Kinesis. Lower priority for PoC.
- **Status:** OPEN (accepted for PoC)

---

## FIXED Vulnerabilities

### VULN-014: Lambda Arbitrary Key Injection and Field Overwrite — FIXED

- **Threat ID:** T6
- **Components:** Lambda flatten function (`terraform/lambda/flatten.py`)
- **Description:** The `flatten_otlp` function called `record.update(sanitize_keys(attrs))` after setting base fields like `service_name` and `event_type`. An attacker with the bearer token could send OTLP payloads with arbitrary attribute keys that would overwrite base fields (e.g., spoof `service_name` or `user_id`) or inject unlimited arbitrary keys to bloat records.
- **Impact:** Dashboard data corruption, user impersonation via field overwrite, resource exhaustion via arbitrary key injection.
- **Fix applied:** Added attribute allowlists (`LOGS_ALLOWED_ATTRS`, `METRICS_ALLOWED_ATTRS`) derived from the Glue table schema. Attributes are filtered through `filter_keys()` after `extract_attrs()` and before `record.update()`, preventing both field overwrite and arbitrary key injection.
- **Status:** FIXED (March 2026)

### VULN-015: gRPC Listener Bypasses OIDC Authentication — FIXED

- **Threat ID:** S6
- **Components:** ALB listener rules (`terraform/modules/alb/main.tf`), OTel Collector config (`terraform/collector/otel-collector-config.yaml`), ECS task definition (`terraform/modules/ecs-collector/main.tf`), VPC security groups (`terraform/modules/vpc/security_groups.tf`), Dockerfile (`terraform/collector/Dockerfile`)
- **Description:** The ALB had a `grpc_passthrough` listener rule (priority 20) that forwarded gRPC traffic (`content-type: application/grpc`) directly to the collector without any `authenticate-oidc` action. The collector also exposed a gRPC receiver on port 4317. This created a two-tier auth model where gRPC clients bypassed the OIDC identity layer entirely, authenticating only with the shared bearer token. Claude Code uses HTTP/protobuf exclusively — the gRPC path was unused.
- **Impact:** Complete OIDC bypass for any client sending gRPC. Attacker could switch to gRPC to avoid identity checks.
- **Fix applied:** Removed the `grpc_passthrough` ALB listener rule, removed the gRPC receiver from the OTel Collector config, removed port 4317 from the ECS task definition and Dockerfile, and deleted the associated VPC security group rules (`alb_to_collector_grpc`, `collector_grpc`). Only HTTP/protobuf ingestion on port 4318 remains.
- **Status:** FIXED (March 2026)

---

## MITIGATED Vulnerabilities

### VULN-016: Zero ALB-Layer Auth When ACM Certificate Absent

- **Threat ID:** S7
- **Components:** ALB listener rules (`terraform/modules/alb/main.tf`)
- **Description:** The OIDC listener rule has `count = local.has_acm_cert && var.cognito_user_pool_id != "" ? 1 : 0`. When `acm_certificate_arn` is empty (PoC default), both OIDC rules get `count = 0` and the default listener action forwards all traffic without identity checks. Even if Cognito is configured, OIDC is silently disabled without an ACM certificate. This is an AWS ALB requirement (OIDC actions require a valid certificate), but the silent degradation is a misconfiguration risk.
- **Impact:** If an operator configures Cognito but forgets the ACM cert, they believe OIDC is active when it is not. All traffic authenticated only by the shared bearer token.
- **Mitigation applied:** Added a Terraform `check` block (`cognito_requires_acm`) that raises an error during `terraform plan` if `cognito_user_pool_id` is set without `acm_certificate_arn`. Updated DEPLOYMENT.md to document that ACM is required for OIDC.
- **Residual risk:** In the PoC (no ACM cert, no Cognito), the ALB has no identity-layer auth by design — only the bearer token at the collector provides authentication.
- **Status:** MITIGATED (March 2026) — guardrail prevents misconfiguration; full fix requires ACM certificate for production

---

## Remediation Priority (for Production Readiness)

| Priority                  | Vulnerability                                 | Effort      |
| ------------------------- | --------------------------------------------- | ----------- |
| P1 — Before production    | VULN-001 (shared bearer token → OIDC)         | 1-2 weeks   |
| P1 — Before production    | VULN-002 (PII redaction — REOPENED)           | 3-5 days    |
| P1 — Before production    | VULN-003 (self-signed TLS)                    | 1 day       |
| P1 — Before production    | VULN-007 (CloudTrail)                         | 1 day       |
| P1 — Before production    | VULN-012 (unmasked prompts in S3)             | 3-5 days    |
| P2 — Production hardening | VULN-004 (data volume cost bomb)              | 2-3 days    |
| P2 — Production hardening | VULN-005 (token in env var → Secrets Manager) | 2 hours     |
| P2 — Production hardening | VULN-006 (state file → S3 backend)            | 2 hours     |
| P2 — Production hardening | VULN-008 (Grafana RLS)                        | 3-5 days    |
| P2 — Production hardening | VULN-013 (Lambda code signing)                | 1 day       |
| P1 — Before production    | VULN-016 (ACM cert for OIDC)                  | 1 day       |
| P3 — Nice to have         | VULN-009, VULN-010, VULN-011                  | 1 day total |
| FIXED                     | VULN-014 (Lambda key injection/overwrite)     | Done        |
| FIXED                     | VULN-015 (gRPC OIDC bypass)                   | Done        |
