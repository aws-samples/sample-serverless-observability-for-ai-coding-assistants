# -----------------------------------------------------------------------------
# Terraform Backend — Local State
# Switch to S3 backend for production deployments.
# -----------------------------------------------------------------------------

# Using local backend by default.
# To switch to S3 remote state:
# 1. Create the S3 bucket and DynamoDB table
# 2. Uncomment the block below and run `terraform init -migrate-state`
#
# terraform {
#   backend "s3" {
#     bucket         = "claude-code-telemetry-tfstate"
#     key            = "terraform.tfstate"
#     region         = "us-east-1"
#     encrypt        = true
#     dynamodb_table = "claude-code-telemetry-tflock"
#   }
# }
