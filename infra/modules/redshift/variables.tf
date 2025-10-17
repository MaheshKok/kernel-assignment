variable "name_prefix" {
  description = "Prefix for resource names"
  type        = string
}

variable "subnet_ids" {
  description = "List of subnet IDs for Redshift"
  type        = list(string)
}

variable "security_group_ids" {
  description = "List of security group IDs for Redshift"
  type        = list(string)
}

variable "database_name" {
  description = "Name of the database"
  type        = string
  default     = "eav_analytics"
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

variable "node_type" {
  description = "Redshift node type"
  type        = string
}

variable "number_of_nodes" {
  description = "Number of nodes in Redshift cluster"
  type        = number
  default     = 1
}

variable "snapshot_retention_period" {
  description = "Snapshot retention period in days"
  type        = number
  default     = 3
}

variable "create_final_snapshot" {
  description = "Create final snapshot on deletion"
  type        = bool
  default     = false
}

variable "tags" {
  description = "Common tags to apply to all resources"
  type        = map(string)
  default     = {}
}
