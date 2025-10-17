# ============================================================================
# RDS MODULE
# ============================================================================
# Creates RDS PostgreSQL instance, replicas, proxy, and related resources
# ============================================================================

resource "aws_db_subnet_group" "rds" {
  name       = "${var.name_prefix}-rds-subnet"
  subnet_ids = var.subnet_ids
  tags = merge(
    var.tags,
    { Name = "${var.name_prefix}-rds-subnet" }
  )
}

resource "aws_db_parameter_group" "postgres" {
  name_prefix = "${var.name_prefix}-pg15-"
  family      = "postgres15"

  # FIXED: pg_partman_bgw background worker not supported in RDS
  # Use pg_partman extension instead (install via CREATE EXTENSION)
  parameter {
    name  = "shared_preload_libraries"
    value = "pg_stat_statements"  
  }
  parameter {
    name  = "max_connections"
    value = var.max_connections
  }
  parameter {
    name  = "work_mem"
    value = "32768" # 32MB
  }
  parameter {
    name  = "maintenance_work_mem"
    value = "2097152" # 2GB
  }
  parameter {
    name  = "wal_level"
    value = "logical"
  }
  parameter {
    name  = "max_wal_senders"
    value = "20"
  }
  parameter {
    name  = "max_replication_slots"
    value = "20"
  }
  # FIXED: synchronous_commit should be set at SESSION level in application
  # Not set globally to preserve strong consistency for critical writes
  # Use: SET LOCAL synchronous_commit = off; in stage_flush() function

  tags = merge(
    var.tags,
    { Name = "${var.name_prefix}-postgres-params" }
  )

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_db_instance" "postgres" {
  identifier = "${var.name_prefix}-postgres"

  engine         = "postgres"
  engine_version = "15.4"
  instance_class = var.instance_class

  allocated_storage     = var.allocated_storage
  max_allocated_storage = var.allocated_storage * 2
  storage_type          = "gp3"
  storage_encrypted     = true
  iops                  = var.iops
  storage_throughput    = var.storage_throughput

  db_name  = var.database_name
  username = var.master_username
  password = var.master_password

  db_subnet_group_name   = aws_db_subnet_group.rds.name
  vpc_security_group_ids = var.security_group_ids
  parameter_group_name   = aws_db_parameter_group.postgres.name

  multi_az                = var.multi_az
  backup_retention_period = var.backup_retention_period
  backup_window           = "03:00-04:00"
  maintenance_window      = "sun:04:00-sun:05:00"

  enabled_cloudwatch_logs_exports = ["postgresql", "upgrade"]

  performance_insights_enabled          = var.enable_enhanced_monitoring
  performance_insights_retention_period = var.enable_enhanced_monitoring ? 731 : 0

  monitoring_interval = var.enable_enhanced_monitoring ? 60 : 0
  monitoring_role_arn = var.enable_enhanced_monitoring ? var.monitoring_role_arn : null

  deletion_protection       = var.deletion_protection
  skip_final_snapshot       = !var.deletion_protection
  final_snapshot_identifier = var.deletion_protection ? "${var.name_prefix}-final-${formatdate("YYYYMMDD-hhmm", timestamp())}" : null

  tags = merge(
    var.tags,
    { Name = "${var.name_prefix}-postgres" }
  )
}

resource "aws_db_instance" "postgres_replica" {
  count               = var.replica_count
  identifier          = "${var.name_prefix}-postgres-replica-${count.index + 1}"
  replicate_source_db = aws_db_instance.postgres.identifier
  instance_class      = var.instance_class
  skip_final_snapshot = true
  publicly_accessible = false

  tags = merge(
    var.tags,
    { Name = "${var.name_prefix}-postgres-replica-${count.index + 1}" }
  )
}

# ============================================================================
# RDS PROXY (connection pooling)
# ============================================================================

resource "aws_db_proxy" "postgres" {
  name          = "${var.name_prefix}-proxy"
  engine_family = "POSTGRESQL"
  
  auth {
    auth_scheme = "SECRETS"
    iam_auth    = "DISABLED"
    secret_arn  = var.proxy_secret_arn
  }

  role_arn       = var.proxy_role_arn
  vpc_subnet_ids = var.subnet_ids
  require_tls    = true

  tags = merge(
    var.tags,
    { Name = "${var.name_prefix}-rds-proxy" }
  )
}

resource "aws_db_proxy_default_target_group" "postgres" {
  db_proxy_name = aws_db_proxy.postgres.name

  connection_pool_config {
    max_connections_percent      = 100
    max_idle_connections_percent = 50
    connection_borrow_timeout    = 120
  }
}

resource "aws_db_proxy_target" "postgres" {
  db_proxy_name          = aws_db_proxy.postgres.name
  target_group_name      = aws_db_proxy_default_target_group.postgres.name
  db_instance_identifier = aws_db_instance.postgres.id
}
