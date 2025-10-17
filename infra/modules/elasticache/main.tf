# ============================================================================
# ELASTICACHE MODULE
# ============================================================================
# Creates ElastiCache Redis cluster with parameter groups
# ============================================================================

resource "aws_elasticache_subnet_group" "redis" {
  name       = "${var.name_prefix}-redis-subnet"
  subnet_ids = var.subnet_ids
  tags = merge(
    var.tags,
    { Name = "${var.name_prefix}-redis-subnet" }
  )
}

resource "aws_elasticache_parameter_group" "redis" {
  name   = "${var.name_prefix}-redis-params"
  family = "redis7"

  parameter {
    name  = "maxmemory-policy"
    value = "allkeys-lru"
  }
  parameter {
    name  = "timeout"
    value = "300"
  }
}

resource "aws_elasticache_replication_group" "redis" {
  replication_group_id = "${var.name_prefix}-redis"
  description          = "Redis cache for EAV hot data"
  
  engine               = "redis"
  engine_version       = "7.0"
  node_type            = var.node_type
  num_cache_clusters   = var.num_cache_clusters
  port                 = 6379

  parameter_group_name = aws_elasticache_parameter_group.redis.name
  subnet_group_name    = aws_elasticache_subnet_group.redis.name
  security_group_ids   = var.security_group_ids

  automatic_failover_enabled = var.num_cache_clusters > 1
  multi_az_enabled           = var.num_cache_clusters > 1

  at_rest_encryption_enabled = true
  transit_encryption_enabled = true

  snapshot_retention_limit = var.snapshot_retention_limit
  snapshot_window          = "03:00-05:00"
  maintenance_window       = "sun:05:00-sun:07:00"

  tags = merge(
    var.tags,
    { Name = "${var.name_prefix}-redis" }
  )
}
