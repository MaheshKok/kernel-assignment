# EAV Platform - Terraform Infrastructure

This directory contains modular Terraform configuration for the EAV platform infrastructure.

## Quick Start (TL;DR)

```bash
# 1. Create secrets in AWS Secrets Manager
cd infra
./scripts/create-secrets.sh dev  # Save the passwords!

# 2. Initialize and apply Terraform
terraform init
terraform plan -var environment=dev
terraform apply -var environment=dev

# 3. Get connection endpoints
terraform output rds_proxy_endpoint
terraform output redis_endpoint
```

**Note:** No passwords in tfvars! All credentials fetched from AWS Secrets Manager.

---

## Structure

```
infra/
├── main.tf              # Module orchestration (CURRENT - use this)
├── variables.tf         # Input variables
├── outputs.tf           # Output values
├── versions.tf          # Provider versions
├── locals.tf            # Environment configurations
├── data.tf              # Data sources placeholder
├── main-old.tf          # LEGACY ONLY - DO NOT USE (monolithic backup)
└── modules/
    ├── vpc/             # VPC, subnets, NAT gateways
    ├── security_groups/ # Security groups for all services
    ├── rds/             # RDS PostgreSQL + replicas + proxy
    ├── elasticache/     # Redis cluster
    ├── redshift/        # Redshift cluster
    ├── iam/             # IAM roles and policies
    ├── secrets/         # Secrets Manager
    └── monitoring/      # CloudWatch alarms
```

## Modules

### VPC (`modules/vpc`)
- VPC with DNS support
- 3 public subnets
- 3 private DB subnets
- 3 private cache subnets
- NAT gateways (1 for dev, 3 for prod)
- Route tables and associations

### Security Groups (`modules/security_groups`)
- App security group (egress only)
- RDS security group (port 5432 from app)
- Redis security group (port 6379 from app)
- Redshift security group (port 5439 from app)

### RDS (`modules/rds`)
- PostgreSQL 15.4 primary instance
- Read replicas (0-3 based on environment)
- RDS Proxy for connection pooling
- Parameter groups with optimized settings
- Subnet groups

### ElastiCache (`modules/elasticache`)
- Redis 7.0 replication group
- Parameter groups (LRU eviction)
- Multi-AZ support for prod
- Encryption at rest and in transit

### Redshift (`modules/redshift`)
- Redshift cluster (single or multi-node)
- Subnet groups
- Encryption and enhanced VPC routing

### IAM (`modules/iam`)
- RDS enhanced monitoring role
- RDS Proxy role with Secrets Manager access

### Secrets Manager (`modules/secrets`)
- RDS credentials storage
- JSON-formatted secrets

### Monitoring (`modules/monitoring`)
- RDS CPU and storage alarms
- Replica lag alarms
- Redis CPU alarms

## Usage

### Prerequisites

**IMPORTANT:** Before running Terraform, you must create secrets in AWS Secrets Manager.

#### Step 1: Create Secrets in AWS Secrets Manager

Use the provided script to create secrets with auto-generated passwords:

```bash
cd infra
./scripts/create-secrets.sh dev  # or prod/staging
```

This creates:
- `eav-platform/rds-credentials` - RDS username and password
- `eav-platform/redshift-credentials` - Redshift username and password

**Save the generated passwords securely!**

Alternatively, create secrets manually:

```bash
# RDS credentials
aws secretsmanager create-secret \
  --name eav-platform/rds-credentials \
  --secret-string '{"username":"eav_admin","password":"your-secure-password"}' \
  --region us-east-1

# Redshift credentials
aws secretsmanager create-secret \
  --name eav-platform/redshift-credentials \
  --secret-string '{"username":"eav_admin","password":"your-secure-password"}' \
  --region us-east-1
```

#### Step 2: Initialize Terraform

```bash
cd infra
terraform init
```

#### Step 3: Plan

```bash
# Dev environment
terraform plan -var environment=dev

# Prod environment
terraform plan -var environment=prod
```

Note: No password variables required! Credentials are fetched from AWS Secrets Manager.

#### Step 4: Apply

```bash
terraform apply -var environment=prod
```

### Using tfvars files

Create environment-specific tfvars files:

```bash
# environments/dev.tfvars
environment = "dev"
region = "us-east-1"

# environments/prod.tfvars
environment = "prod"
region = "us-east-1"
```

Then apply:

```bash
terraform apply -var-file=environments/prod.tfvars
```

### Custom Secret Names

If you want to use different secret names:

```bash
terraform apply \
  -var environment=prod \
  -var rds_secret_name=my-custom/rds-creds \
  -var redshift_secret_name=my-custom/redshift-creds
```

## Environment Configurations

Configured in `locals.tf`:

| Resource         | Dev          | Staging      | Prod         |
|------------------|--------------|--------------|--------------|
| RDS Instance     | r6g.large    | r6g.2xlarge  | r6g.8xlarge  |
| RDS Replicas     | 0            | 1            | 3            |
| Redis Nodes      | 1            | 2            | 3            |
| Redshift Nodes   | 1            | 2            | 3            |
| NAT Gateways     | 1            | 1            | 3            |
| Multi-AZ         | false        | true         | true         |
| Est. Cost/month  | ~$500        | ~$3K         | ~$12K        |

## Helper Scripts

Convenient scripts for common tasks:

### `scripts/create-secrets.sh`
Creates secrets in AWS Secrets Manager with auto-generated passwords.

```bash
./scripts/create-secrets.sh dev
```

⚠️ **Security:** Passwords displayed on screen. Run in secure environment.

### `fix-vscode-cache.sh`
Clears stale Terraform module cache that causes VSCode warnings.

```bash
./fix-vscode-cache.sh
```

Use when VSCode shows "Required attribute not specified" errors.

---

## Outputs

After applying, retrieve outputs:

```bash
# All outputs
terraform output

# Specific output
terraform output rds_proxy_endpoint

# JSON format
terraform output -json
```

## Module Development

Each module follows this structure:

```
modules/<module_name>/
├── main.tf       # Resources
├── variables.tf  # Input variables
└── outputs.tf    # Output values
```

To add a new module:

1. Create directory under `modules/`
2. Define resources in `main.tf`
3. Declare inputs in `variables.tf`
4. Export outputs in `outputs.tf`
5. Call module from root `main.tf`

## Migration from Monolithic Config

⚠️ **IMPORTANT:** The original monolithic configuration is preserved as `main-old.tf` **for reference only**.

**DO NOT USE `main-old.tf`** - it is:
- Outdated and does not use AWS Secrets Manager
- Missing recent security improvements
- Kept only for historical comparison

### Comparing Configurations

To see what changed during modularization:

```bash
# View structural differences
diff main-old.tf main.tf

# Count resources in each
grep -c "^resource" main-old.tf
find modules -name "main.tf" -exec grep -c "^resource" {} \; | awk '{s+=$1} END {print s}'
```

### If You Must Restore Legacy (NOT RECOMMENDED)

```bash
# Backup modular config first
mv main.tf main-modular.tf
mv main-old.tf main.tf

# Re-add password variables to variables.tf
# WARNING: This removes Secrets Manager integration
```

## Security Best Practices

### Secrets Management

✅ **Current Implementation:**
- All passwords fetched from AWS Secrets Manager
- No hardcoded credentials in code
- Secrets managed outside Terraform state
- Auto-generated strong passwords

### IAM Permissions Required

The AWS user/role running Terraform needs:

```json
{
  "Effect": "Allow",
  "Action": [
    "secretsmanager:GetSecretValue",
    "secretsmanager:DescribeSecret"
  ],
  "Resource": [
    "arn:aws:secretsmanager:*:*:secret:eav-platform/*"
  ]
}
```

### Secret Rotation

To rotate credentials:

```bash
# Update secret in AWS Secrets Manager
aws secretsmanager put-secret-value \
  --secret-id eav-platform/rds-credentials \
  --secret-string '{"username":"eav_admin","password":"new-password"}'

# Apply Terraform to update resources
terraform apply -var environment=prod
```

## Best Practices

1. **Remote State**: Configure S3 backend in `versions.tf`
2. **State Locking**: Use DynamoDB for state locking
3. **Secrets**: ✅ Already using AWS Secrets Manager
4. **Tags**: All resources inherit common tags from `locals.tf`
5. **Naming**: Resources use `${project_name}-${environment}` prefix
6. **Never** commit terraform.tfstate or *.tfvars with secrets

## Additional Documentation

Detailed guides for specific topics:

| Document | Purpose |
|----------|----------|
| **README.md** (this file) | Overview, usage, general reference |
| **VSCODE-FIX.md** | Fix VSCode Terraform warnings (START HERE if errors) |
| **SECRETS.md** | Complete secrets management guide |
| **CHANGELOG-SECRETS.md** | Version history, what changed |
| **BUGFIXES.md** | Detailed bug analysis and fixes |
| **FIXES-SUMMARY.md** | Quick bug fix summary |
| **modules/*/README.md** | Module-specific documentation |

### Quick Links

- **Setting up secrets?** → See `SECRETS.md`
- **VSCode warnings?** → See "Troubleshooting" below
- **What changed?** → See `CHANGELOG-SECRETS.md`
- **Understanding modules?** → See "Modules" section above
- **Adding a new module?** → See "Module Development" section

---

## Troubleshooting

### VSCode Shows "Required attribute not specified" Warnings

**Problem:** VSCode displays errors like:
```
Required attribute "rds_username" not specified
Required attribute "rds_password" not specified
```

**Cause:** Stale module cache from previous configuration.

**Solution:**
```bash
# Quick fix
./fix-vscode-cache.sh

# Or manually:
rm -rf .terraform .terraform.lock.hcl
terraform init

# Then reload VSCode
# Cmd+Shift+P (Mac) or Ctrl+Shift+P (Windows/Linux)
# Type: "Reload Window"
```

### Module not found

```bash
terraform init  # Re-initialize to download modules
```

### State issues

```bash
terraform state list  # View resources in state
terraform state show <resource>  # Inspect specific resource
```

### Validation

```bash
terraform validate  # Check configuration syntax
terraform fmt -recursive  # Format all files
```

---

## Command Reference Card

Quick reference for common operations:

### Initial Setup
```bash
# Create secrets (one-time)
./scripts/create-secrets.sh dev

# Initialize Terraform
terraform init
```

### Daily Operations
```bash
# Plan changes
terraform plan -var environment=dev

# Apply changes
terraform apply -var environment=prod

# View outputs
terraform output
terraform output -json | jq

# Destroy (careful!)
terraform destroy -var environment=dev
```

### Secrets Management
```bash
# View secret
aws secretsmanager get-secret-value \
  --secret-id eav-platform/rds-credentials \
  --query SecretString --output text | jq

# Rotate password
aws secretsmanager put-secret-value \
  --secret-id eav-platform/rds-credentials \
  --secret-string '{"username":"eav_admin","password":"new-pass"}'

# Apply after rotation
terraform apply -var environment=prod
```

### Troubleshooting
```bash
# Clear cache (VSCode warnings)
./fix-vscode-cache.sh

# Validate configuration
terraform validate

# Format code
terraform fmt -recursive

# View state
terraform state list
terraform state show module.rds.aws_db_instance.postgres
```

### Environment Management
```bash
# Using tfvars files
terraform apply -var-file=environments/dev.tfvars
terraform apply -var-file=environments/prod.tfvars

# Or inline
terraform apply -var environment=staging
```

### Secrets not found

**Error:**
```
Error: reading Secrets Manager Secret (eav-platform/rds-credentials): ResourceNotFoundException
```

**Solution:**
```bash
# Create secrets first
./scripts/create-secrets.sh dev
```

See `SECRETS.md` for detailed troubleshooting.
