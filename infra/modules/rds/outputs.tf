output "db_instance_endpoint" {
  description = "RDS PostgreSQL primary endpoint"
  value       = aws_db_instance.postgres.endpoint
}

output "db_instance_id" {
  description = "RDS PostgreSQL instance ID"
  value       = aws_db_instance.postgres.id
}

output "db_proxy_endpoint" {
  description = "RDS Proxy endpoint"
  value       = aws_db_proxy.postgres.endpoint
}

output "replica_endpoints" {
  description = "RDS read replica endpoints"
  value       = [for r in aws_db_instance.postgres_replica : r.endpoint]
}

output "replica_instance_ids" {
  description = "RDS read replica instance IDs"
  value       = [for r in aws_db_instance.postgres_replica : r.id]
}
