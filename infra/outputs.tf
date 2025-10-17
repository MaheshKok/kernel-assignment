# ============================================================================
# OUTPUTS (Connection Endpoints)
# ============================================================================
#
# Use these outputs to configure:
# - Application connection strings
# - Debezium CDC connector (rds_endpoint)
# - Redis cache client (redis_endpoint)
# - Analytics tools (redshift_endpoint)
#
# Example:
#   terraform output -json | jq -r '.rds_proxy_endpoint.value'
# ============================================================================

output "vpc_id" {
  description = "VPC ID (for additional resource deployment)"
  value       = module.vpc.vpc_id
}

output "rds_endpoint" {
  description = "RDS PostgreSQL primary endpoint (direct connection)"
  value       = module.rds.db_instance_endpoint
}

output "rds_proxy_endpoint" {
  description = "RDS Proxy endpoint (recommended for application connections)"
  value       = module.rds.db_proxy_endpoint
}

output "rds_replica_endpoints" {
  description = "RDS read replica endpoints (for read-only queries)"
  value       = module.rds.replica_endpoints
}

output "redis_endpoint" {
  description = "Redis primary endpoint (for writes and reads)"
  value       = module.elasticache.redis_primary_endpoint
}

output "redis_reader_endpoint" {
  description = "Redis reader endpoint (read-only, load balanced)"
  value       = module.elasticache.redis_reader_endpoint
}

output "redshift_endpoint" {
  description = "Redshift cluster endpoint (for analytics queries)"
  value       = module.redshift.redshift_endpoint
}
