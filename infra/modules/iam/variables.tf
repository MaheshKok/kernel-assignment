variable "name_prefix" {
  description = "Prefix for resource names"
  type        = string
}

variable "enable_rds_monitoring" {
  description = "Enable RDS enhanced monitoring role"
  type        = bool
  default     = false
}

variable "rds_secret_arn" {
  description = "ARN of RDS credentials secret"
  type        = string
}

variable "tags" {
  description = "Common tags to apply to all resources"
  type        = map(string)
  default     = {}
}
