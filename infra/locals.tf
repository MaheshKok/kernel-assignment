locals {
  common_tags = {
    Environment = var.environment
    Project     = var.project_name
    ManagedBy   = "Terraform"
  }

  # ========================================================================
  # ENVIRONMENT PARAMETERIZATION
  # ========================================================================
  # Demonstrates cost vs. performance trade-offs across environments:
  #
  # | Resource    | Dev            | Staging        | Prod              |
  # |-------------|----------------|----------------|-------------------|
  # | RDS         | r6g.large      | r6g.2xlarge    | r6g.8xlarge       |
  # | RDS Replicas| 0              | 1              | 3                 |
  # | Redis       | r6g.large      | r6g.xlarge     | r6g.2xlarge       |
  # | Redshift    | dc2.large      | dc2.large      | ra3.4xlarge       |
  # | Multi-AZ    | false          | true           | true              |
  # | Est. Cost   | ~$500/month    | ~$3K/month     | ~$12K/month       |
  # ========================================================================

  env_config = {
    dev = {
      rds_instance               = "db.r6g.large"
      rds_storage                = 200
      rds_multi_az               = false
      rds_replicas               = 0
      rds_iops                   = 12000
      rds_storage_throughput     = 500
      rds_max_connections        = "500"
      redis_node_type            = "cache.r6g.large"
      redis_nodes                = 1
      redshift_node_type         = "dc2.large"
      redshift_nodes             = 1
      vpc_cidr                   = "10.0.0.0/16"
      nat_gateway_count          = 1
      enable_enhanced_monitoring = false
      backup_retention           = 1
      redis_snapshot_retention   = 1
      redshift_snapshot_retention = 3
      deletion_protection        = false
    }
    staging = {
      rds_instance               = "db.r6g.2xlarge"
      rds_storage                = 1000
      rds_multi_az               = true
      rds_replicas               = 1
      rds_iops                   = 12000
      rds_storage_throughput     = 500
      rds_max_connections        = "1000"
      redis_node_type            = "cache.r6g.xlarge"
      redis_nodes                = 2
      redshift_node_type         = "dc2.large"
      redshift_nodes             = 2
      vpc_cidr                   = "10.1.0.0/16"
      nat_gateway_count          = 1
      enable_enhanced_monitoring = true
      backup_retention           = 7
      redis_snapshot_retention   = 3
      redshift_snapshot_retention = 7
      deletion_protection        = false
    }
    prod = {
      rds_instance               = "db.r6g.8xlarge"
      rds_storage                = 5000
      rds_multi_az               = true
      rds_replicas               = 3
      rds_iops                   = 16000
      rds_storage_throughput     = 1000
      rds_max_connections        = "2000"
      redis_node_type            = "cache.r6g.2xlarge"
      redis_nodes                = 3
      redshift_node_type         = "ra3.4xlarge"
      redshift_nodes             = 3
      vpc_cidr                   = "10.2.0.0/16"
      nat_gateway_count          = 3
      enable_enhanced_monitoring = true
      backup_retention           = 30
      redis_snapshot_retention   = 7
      redshift_snapshot_retention = 35
      deletion_protection        = true
    }
  }

  current     = local.env_config[var.environment]
  name_prefix = "${var.project_name}-${var.environment}"
}
