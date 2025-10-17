variable "name_prefix" {
  description = "Prefix for resource names"
  type        = string
}

variable "subnet_ids" {
  description = "List of subnet IDs for ElastiCache"
  type        = list(string)
}

variable "security_group_ids" {
  description = "List of security group IDs for ElastiCache"
  type        = list(string)
}

variable "node_type" {
  description = "ElastiCache node type"
  type        = string
}

variable "num_cache_clusters" {
  description = "Number of cache clusters"
  type        = number
  default     = 1
}

variable "snapshot_retention_limit" {
  description = "Snapshot retention limit in days"
  type        = number
  default     = 1
}

variable "tags" {
  description = "Common tags to apply to all resources"
  type        = map(string)
  default     = {}
}
