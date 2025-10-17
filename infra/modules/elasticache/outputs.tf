output "redis_primary_endpoint" {
  description = "Redis primary endpoint"
  value       = aws_elasticache_replication_group.redis.primary_endpoint_address
}

output "redis_reader_endpoint" {
  description = "Redis reader endpoint"
  value       = aws_elasticache_replication_group.redis.reader_endpoint_address
}

output "redis_replication_group_id" {
  description = "Redis replication group ID"
  value       = aws_elasticache_replication_group.redis.id
}
