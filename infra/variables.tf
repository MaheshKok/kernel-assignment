variable "environment" {
  description = "Environment (dev/staging/prod)"
  type        = string
  validation {
    condition     = contains(["dev", "staging", "prod"], var.environment)
    error_message = "Must be dev, staging, or prod."
  }
}

variable "region" {
  description = "AWS region"
  type        = string
  default     = "us-east-1"
}

variable "project_name" {
  description = "Project name"
  type        = string
  default     = "eav-platform"
}

variable "rds_secret_name" {
  description = "Name of the AWS Secrets Manager secret containing RDS credentials"
  type        = string
  default     = "eav-platform/rds-credentials"
}

variable "redshift_secret_name" {
  description = "Name of the AWS Secrets Manager secret containing Redshift credentials"
  type        = string
  default     = "eav-platform/redshift-credentials"
}
