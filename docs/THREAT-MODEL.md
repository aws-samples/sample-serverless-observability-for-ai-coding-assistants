# Threat Model — Claude Code Telemetry Platform

**Scope:** PoC deployment (dev environment)
**Date:** March 2026
**Methodology:** STRIDE + Follow-the-Data + Follow-the-Workflow + Follow-the-User

---

## 1. System Overview

The platform collects OpenTelemetry metrics and logs from Claude Code IDE sessions on developer laptops, ingests them through an internet-facing ALB into an OTel Collector running on ECS Fargate, and routes both metrics and logs to Kinesis Data Streams. Firehose delivery streams read from Kinesis, invoke a Lambda function to flatten nested OTLP JSON into flat records, convert to Parquet, and deliver to S3. Amazon Athena queries the Parquet data via Glue Data Catalog, and Amazon Managed Grafana visualizes it using the Athena data source. Authentication is bearer-token-based at the collector layer. Backend traffic from the collector flows through VPC endpoints. Grafana reaches the Athena API via a NAT gateway (internet).

### Components

| Component                    | Purpose                                               | Network                       |
| ---------------------------- | ----------------------------------------------------- | ----------------------------- |
| ALB + WAF                    | Public OTLP ingestion, TLS termination, rate limiting | Public subnet                 |
| ECS Fargate (OTel Collector) | Receives OTLP, exports to Kinesis Data Streams        | Private subnet, VPC endpoints |
| Kinesis Data Streams (2)     | Buffered ingestion for metrics and logs               | Via VPC endpoint              |
| Firehose + Lambda            | Flatten OTLP JSON, convert to Parquet, deliver to S3  | AWS managed                   |
| S3 Telemetry Archive         | Single data store — Parquet files (metrics/ + logs/)  | Via VPC endpoint              |
| Glue Data Catalog            | Schema definitions, partition projection              | AWS managed                   |
| Athena                       | SQL queries on S3 Parquet data                        | AWS managed                   |
| Amazon Managed Grafana       | Dashboards (Athena data source)                       | Private subnet, NAT gateway   |
| ECR                          | Collector container image                             | Via VPC endpoint              |

### VPC Endpoints

S3, ECR (api + dkr), Kinesis Streams, CloudWatch Logs (for ECS container logs), STS, Monitoring.

### Trust Boundaries

```text
TB1: Internet ↔ ALB (public ingestion endpoint)
TB2: ALB ↔ ECS Fargate (private subnets)
TB3: ECS Fargate ↔ Kinesis Data Streams (via VPC endpoint)
TB4: Kinesis ↔ Firehose + Lambda ↔ S3 (AWS managed, IAM-controlled)
TB5: Corporate network ↔ Grafana workspace
TB6: Grafana ↔ Athena API (via NAT gateway / internet)
TB7: Operator workstation ↔ AWS APIs (Terraform, CLI)
```

### Data Classification

| Data Type                                | Sensitivity                           | Where Stored                         |
| ---------------------------------------- | ------------------------------------- | ------------------------------------ |
| User prompts (full text)                 | HIGH — may contain code, secrets, PII | S3 Parquet (logs/) — stored unmasked |
| Token usage / cost metrics               | MEDIUM — usage patterns per user      | S3 Parquet (metrics/)                |
| Session metadata (user_id, org_id)       | MEDIUM — identifies individuals       | S3 Parquet (both tables)             |
| Tool decisions (accept/reject)           | LOW                                   | S3 Parquet (logs/)                   |
| Infrastructure config (tfvars, API keys) | HIGH                                  | Local filesystem, tfstate            |
| Bearer token (telemetry_api_key)         | HIGH — grants write access            | tfvars, tfstate, ECS env var         |
| Grafana API key                          | HIGH — admin access to dashboards     | Operator's shell history             |

---

## 2. STRIDE Analysis

### 2.1 Spoofing

| ID  | Threat                                          | Component           | Risk   | Notes                                                                                                                                                                                   |
| --- | ----------------------------------------------- | ------------------- | ------ | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| S1  | Attacker impersonates a legitimate client       | ALB → Collector     | HIGH   | Static shared bearer token. No per-user identity at ingestion.                                                                                                                          |
| S2  | Attacker replays a captured bearer token        | ALB → Collector     | HIGH   | No token rotation, expiry, or nonce.                                                                                                                                                    |
| S3  | Attacker spoofs user_id/org_id in payloads      | Collector → Kinesis | HIGH   | Collector trusts all OTLP payload fields. No server-side identity validation.                                                                                                           |
| S4  | Compromised laptop sends malicious telemetry    | Client → ALB        | MEDIUM | Inherent to client-side instrumentation.                                                                                                                                                |
| S5  | Unauthorized user accesses Grafana              | Grafana             | LOW    | SAML/SSO authentication required. Corporate CIDR restriction on SG.                                                                                                                     |
| S6  | gRPC clients bypass OIDC identity layer         | ALB → Collector     | HIGH   | **FIXED.** gRPC passthrough rule forwarded without OIDC auth. Removed gRPC listener rule, collector gRPC receiver, ECS port mapping, VPC security group rules, and Dockerfile exposure. |
| S7  | Silent auth degradation without ACM certificate | ALB                 | HIGH   | **MITIGATED.** OIDC rules have count=0 when acm_certificate_arn is empty. Terraform check block now prevents Cognito without ACM.                                                       |

### 2.2 Tampering

| ID  | Threat                                                        | Component                | Risk   | Notes                                                                                                                                                                   |
| --- | ------------------------------------------------------------- | ------------------------ | ------ | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| T1  | MITM on telemetry in transit                                  | Client → ALB             | LOW    | Self-signed TLS; clients disable cert validation. MITM trivial on same network. Would be HIGH in production.                                                            |
| T2  | False metric/log injection to corrupt dashboards              | Collector → Kinesis → S3 | HIGH   | Valid bearer token allows arbitrary metric values, labels, and log content.                                                                                             |
| T3  | Tampering with Terraform state                                | Local tfstate            | MEDIUM | Local, unencrypted, contains resource ARNs and bearer token.                                                                                                            |
| T4  | Modifying collector config to exfiltrate data                 | ECS task definition      | LOW    | Requires ECS/ECR write permissions.                                                                                                                                     |
| T5  | Lambda function code tampering                                | Lambda flatten function  | MEDIUM | Attacker with Lambda:UpdateFunctionCode could alter data transformation — drop fields, inject data, or exfiltrate records.                                              |
| T6  | Arbitrary key injection / field overwrite via OTLP attributes | Lambda flatten function  | HIGH   | **FIXED.** Attacker-controlled attributes could overwrite base fields (service_name, user_id) or inject arbitrary keys. Attribute allowlist now enforced in flatten.py. |

### 2.3 Repudiation

| ID  | Threat                                     | Component      | Risk   | Notes                                                         |
| --- | ------------------------------------------ | -------------- | ------ | ------------------------------------------------------------- |
| R1  | Client denies sending specific telemetry   | Ingestion path | HIGH   | Shared token — cannot attribute data to a specific developer. |
| R2  | Admin denies modifying infrastructure      | AWS account    | MEDIUM | CloudTrail disabled for PoC. No audit trail.                  |
| R3  | Grafana user denies viewing sensitive data | Grafana        | MEDIUM | Grafana audit logging not configured.                         |

### 2.4 Information Disclosure

| ID  | Threat                                    | Component           | Risk   | Notes                                                                                                                  |
| --- | ----------------------------------------- | ------------------- | ------ | ---------------------------------------------------------------------------------------------------------------------- |
| D1  | Prompts contain secrets or credentials    | S3 Parquet (logs/)  | HIGH   | No PII/secret redaction in the pipeline. Prompts stored unmasked in S3.                                                |
| D2  | Bearer token in Terraform state           | Local filesystem    | MEDIUM | .gitignore covers state files. Main tfstate still has plaintext secrets.                                               |
| D3  | Bearer token in ECS environment variables | ECS task definition | MEDIUM | Visible via DescribeTaskDefinition API. Not using Secrets Manager.                                                     |
| D4  | Cross-user data visibility in Grafana     | Grafana dashboards  | MEDIUM | No row-level security. Any Grafana user sees all users' data.                                                          |
| D5  | S3 Parquet files contain unmasked prompts | S3 bucket           | HIGH   | Anyone with S3 read access or Athena query access can read full prompt text. No encryption with customer-managed keys. |

### 2.5 Denial of Service

| ID   | Threat                           | Component               | Risk   | Notes                                                                                                                                                                                      |
| ---- | -------------------------------- | ----------------------- | ------ | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| DoS1 | Volumetric attack on ALB         | ALB (public)            | MEDIUM | WAF rate limit 2000 req/5min per IP. Distributed attacks bypass this.                                                                                                                      |
| DoS2 | Data volume flood (cost bomb)    | Kinesis → Firehose → S3 | HIGH   | Attacker with valid bearer token can flood the pipeline with data. Costs scale with Kinesis shard hours, Firehose ingestion volume, S3 storage, Lambda invocations, and Athena scan bytes. |
| DoS3 | ALB deletion protection disabled | ALB                     | LOW    | Accidental terraform destroy removes ingestion endpoint.                                                                                                                                   |

### 2.6 Elevation of Privilege

| ID  | Threat                                            | Component               | Risk | Notes                                                                            |
| --- | ------------------------------------------------- | ----------------------- | ---- | -------------------------------------------------------------------------------- |
| E1  | Operator with Terraform access has implicit admin | AWS account             | LOW  | Expected for PoC.                                                                |
| E2  | Lambda execution role over-permissioned           | Lambda flatten function | LOW  | Currently scoped to basic execution. If broadened, could access other resources. |

---

## 3. Follow the Data

### 3.1 Telemetry Ingestion Path

```text
Developer Laptop → [Internet] → ALB:443 → [VPC Public Subnet] → ECS:4318 → [VPC Private Subnet]
```

| Hop             | Encryption            | Auth                      | Risk                                                 |
| --------------- | --------------------- | ------------------------- | ---------------------------------------------------- |
| Laptop → ALB    | TLS 1.3 (self-signed) | None at ALB               | Client disables cert validation — MITM possible (T1) |
| ALB → Collector | HTTP (within VPC)     | Bearer token at collector | Token in cleartext env var (D3)                      |

### 3.2 Metrics Flow

```text
Collector → Kinesis metrics stream (via VPC endpoint) → Firehose → Lambda flatten → S3 Parquet
```

| Hop                 | Encryption             | Auth                | Risk                                    |
| ------------------- | ---------------------- | ------------------- | --------------------------------------- |
| Collector → Kinesis | HTTPS via VPC endpoint | IAM (task role)     | Low — proper IAM auth, scoped to stream |
| Kinesis → Firehose  | AWS internal           | IAM (firehose role) | Low — managed service                   |
| Firehose → Lambda   | AWS internal           | IAM (firehose role) | Lambda code is an attack surface (T5)   |
| Firehose → S3       | AWS internal           | IAM (firehose role) | Low — scoped to bucket                  |

### 3.3 Logs/Prompts Flow

```text
Collector → Kinesis logs stream (via VPC endpoint) → Firehose → Lambda flatten → S3 Parquet
```

| Hop                              | Encryption             | Auth            | Risk                                           |
| -------------------------------- | ---------------------- | --------------- | ---------------------------------------------- |
| Collector → Kinesis              | HTTPS via VPC endpoint | IAM (task role) | Low — proper IAM auth                          |
| Kinesis → Firehose → Lambda → S3 | AWS internal           | IAM             | Prompts stored unmasked in S3 Parquet (D1, D5) |

### 3.4 Query/Visualization Flow

```text
Grafana → [NAT Gateway] → [Internet] → Athena API → S3 (query results)
```

| Hop              | Encryption            | Auth               | Risk                                                                         |
| ---------------- | --------------------- | ------------------ | ---------------------------------------------------------------------------- |
| Grafana → Athena | HTTPS via NAT gateway | IAM (grafana role) | Traffic traverses internet to reach Athena API. NAT gateway is a dependency. |
| Athena → S3      | AWS internal          | IAM                | Low — scoped to bucket                                                       |

### 3.5 Data at Rest

| Store                             | Encryption            | Retention                | Risk                                                                     |
| --------------------------------- | --------------------- | ------------------------ | ------------------------------------------------------------------------ |
| S3 Parquet (metrics/ + logs/)     | AES-256 (AWS-managed) | Glacier 90d, Expire 365d | Contains unmasked prompts (D1, D5). Single data store for all telemetry. |
| Kinesis Data Streams              | AWS-managed           | 24 hours                 | Transient buffer only                                                    |
| Terraform state                   | None                  | Local file               | Plaintext secrets (D2)                                                   |
| CloudWatch Logs (ECS containers)  | AWS-managed           | 14 days                  | Debugging only — no telemetry data                                       |
| CloudWatch Logs (Firehose errors) | AWS-managed           | 14 days                  | Error records only                                                       |

---

## 4. Follow the Workflow

### 4.1 Deployment Workflow

| Step                              | Threat                                      | Risk |
| --------------------------------- | ------------------------------------------- | ---- |
| Edit terraform.tfvars             | Secrets in plaintext file                   | D2   |
| terraform apply                   | State file written locally with all secrets | D2   |
| Docker build/push                 | Collector image could be tampered           | Low  |
| Lambda function deployed from zip | Code could be modified post-deploy          | T5   |
| Grafana API key creation          | Key shown once, stored in shell history     | Low  |

### 4.2 Client Onboarding Workflow

| Step                               | Threat                                           | Risk   |
| ---------------------------------- | ------------------------------------------------ | ------ |
| Developer receives bearer token    | Shared out-of-band, no rotation                  | S1, S2 |
| Set NODE_TLS_REJECT_UNAUTHORIZED=0 | Disables all TLS validation for the process      | T1     |
| Claude Code sends prompts          | Full prompt text transmitted and stored unmasked | D1, D5 |
| Token embedded in env var          | Visible in process listing, shell history        | S1     |

### 4.3 Incident Response

| Step                           | Threat                                        | Risk |
| ------------------------------ | --------------------------------------------- | ---- |
| No CloudTrail                  | Cannot investigate who did what               | R2   |
| No Grafana audit log           | Cannot track who viewed sensitive data        | R3   |
| S3 data immutable once written | Cannot redact specific prompts after the fact | D5   |

---

## 5. Follow the User

### 5.1 Developer (Claude Code User)

| Action                     | Data Exposed                                          | Risk   |
| -------------------------- | ----------------------------------------------------- | ------ |
| Normal coding session      | Metrics: tokens, cost, session time                   | Low    |
| Prompt logging enabled     | Full prompt text including code snippets stored in S3 | D1, D5 |
| Token shared among team    | Any team member can impersonate another               | S3     |
| Viewing Grafana dashboards | Can see all users' data including prompts             | D4     |

### 5.2 Platform Operator

| Action                         | Data Exposed                             | Risk |
| ------------------------------ | ---------------------------------------- | ---- |
| terraform apply                | Full state with secrets                  | D2   |
| ECS task definition inspection | Bearer token visible                     | D3   |
| S3 bucket access               | All telemetry including unmasked prompts | D5   |
| Lambda function access         | Can modify data transformation logic     | T5   |

### 5.3 Attacker (External)

| Action                  | Prerequisite                          | Impact                                                 |
| ----------------------- | ------------------------------------- | ------------------------------------------------------ |
| Steal bearer token      | Network access or endpoint compromise | Full write access to telemetry pipeline (S1, T2, DoS2) |
| MITM on self-signed TLS | Same network as developer             | Capture bearer token and all telemetry (T1, D1)        |
| Enumerate ALB endpoint  | Public DNS                            | Attempt brute force or DoS (DoS1)                      |

### 5.4 Attacker (Insider — Compromised Developer)

| Action                                | Prerequisite       | Impact                                                             |
| ------------------------------------- | ------------------ | ------------------------------------------------------------------ |
| Submit fake metrics as another user   | Valid bearer token | Corrupt dashboards, frame another user (S3, T2)                    |
| Flood pipeline with data              | Valid bearer token | Cost explosion across Kinesis, Firehose, S3, Lambda, Athena (DoS2) |
| Read other users' prompts via Grafana | Grafana access     | View sensitive code and conversations (D4)                         |
| Read S3 Parquet files directly        | S3 read access     | Access all unmasked prompts (D5)                                   |

---

## 6. Risk Summary

| Risk Level | Count | IDs                                                                  |
| ---------- | ----- | -------------------------------------------------------------------- |
| HIGH       | 9     | S1, S2, S3, T2, D1, D5, DoS2, S6 (FIXED), S7 (MITIGATED), T6 (FIXED) |
| MEDIUM     | 7     | S4, T3, T5, R2, R3, D2, D3, D4, DoS1                                 |
| LOW        | 5     | S5, T1, T4, DoS3, E1, E2                                             |

---

## 7. PoC Accepted Risks

The following are explicitly accepted for the PoC and must be remediated before production:

1. Self-signed TLS with disabled certificate validation (T1)
2. Shared bearer token with no rotation (S1, S2)
3. No per-user identity at ingestion (S3, R1)
4. CloudTrail disabled (R2)
5. Local Terraform state with plaintext secrets (D2)
6. No Grafana row-level security (D4)
7. No PII/secret redaction — prompts stored unmasked in S3 (D1, D5)
8. Lambda function code not integrity-checked (T5)
9. No ALB-layer OIDC auth without ACM certificate (S7) — guardrail added to prevent misconfiguration

### Remediated Threats

The following threats were identified and fixed during the PoC:

1. **T6 — Lambda arbitrary key injection / field overwrite:** Attribute allowlist added to `flatten.py` (VULN-014)
2. **S6 — gRPC OIDC bypass:** gRPC listener rule and receiver removed (VULN-015)
