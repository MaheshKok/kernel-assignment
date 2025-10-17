variable "name_prefix" {
  description = "Prefix for resource names"
  type        = string
}

variable "rds_instance_id" {
  description = "RDS instance ID"
  type        = string
}

variable "rds_replica_ids" {
  description = "List of RDS replica instance IDs"
  type        = list(string)
  default     = []
}

variable "redis_replication_group_id" {
  description = "Redis replication group ID"
  type        = string
}

variable "tags" {
  description = "Common tags to apply to all resources"
  type        = map(string)
  default     = {}
}
