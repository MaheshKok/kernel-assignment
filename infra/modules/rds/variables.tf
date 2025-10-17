variable "name_prefix" {
  description = "Prefix for resource names"
  type        = string
}

variable "subnet_ids" {
  description = "List of subnet IDs for RDS"
  type        = list(string)
}

variable "security_group_ids" {
  description = "List of security group IDs for RDS"
  type        = list(string)
}

variable "instance_class" {
  description = "RDS instance class"
  type        = string
}

variable "allocated_storage" {
  description = "Allocated storage in GB"
  type        = number
}

variable "iops" {
  description = "IOPS for gp3 storage"
  type        = number
  default     = 12000
}

variable "storage_throughput" {
  description = "Storage throughput in MB/s"
  type        = number
  default     = 500
}

variable "database_name" {
  description = "Name of the database"
  type        = string
  default     = "eav_db"
}

variable "master_username" {
  description = "Master username (fetched from Secrets Manager)"
  type        = string
}

variable "master_password" {
  description = "Master password (fetched from Secrets Manager)"
  type        = string
  sensitive   = true
}

variable "multi_az" {
  description = "Enable Multi-AZ"
  type        = bool
  default     = false
}

variable "replica_count" {
  description = "Number of read replicas"
  type        = number
  default     = 0
}

variable "backup_retention_period" {
  description = "Backup retention period in days"
  type        = number
  default     = 7
}

variable "enable_enhanced_monitoring" {
  description = "Enable enhanced monitoring"
  type        = bool
  default     = false
}

variable "monitoring_role_arn" {
  description = "IAM role ARN for enhanced monitoring"
  type        = string
  default     = null
}

variable "deletion_protection" {
  description = "Enable deletion protection"
  type        = bool
  default     = false
}

variable "max_connections" {
  description = "Maximum number of database connections"
  type        = string
  default     = "500"
}

variable "proxy_secret_arn" {
  description = "Secrets Manager ARN for RDS Proxy"
  type        = string
}

variable "proxy_role_arn" {
  description = "IAM role ARN for RDS Proxy"
  type        = string
}

variable "tags" {
  description = "Common tags to apply to all resources"
  type        = map(string)
  default     = {}
}
