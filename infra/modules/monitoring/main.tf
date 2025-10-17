# ============================================================================
# MONITORING MODULE
# ============================================================================

resource "aws_cloudwatch_metric_alarm" "rds_cpu" {
  alarm_name          = "${var.name_prefix}-rds-cpu-high"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 2
  metric_name         = "CPUUtilization"
  namespace           = "AWS/RDS"
  period              = 300
  statistic           = "Average"
  threshold           = 80
  alarm_description   = "RDS CPU > 80%"
  treat_missing_data  = "notBreaching"

  dimensions = {
    DBInstanceIdentifier = var.rds_instance_id
  }

  tags = var.tags
}

resource "aws_cloudwatch_metric_alarm" "rds_storage" {
  alarm_name          = "${var.name_prefix}-rds-storage-low"
  comparison_operator = "LessThanThreshold"
  evaluation_periods  = 1
  metric_name         = "FreeStorageSpace"
  namespace           = "AWS/RDS"
  period              = 300
  statistic           = "Average"
  threshold           = 10737418240 # 10GB
  alarm_description   = "RDS free storage < 10GB"

  dimensions = {
    DBInstanceIdentifier = var.rds_instance_id
  }

  tags = var.tags
}

resource "aws_cloudwatch_metric_alarm" "rds_replica_lag" {
  count               = length(var.rds_replica_ids)
  alarm_name          = "${var.name_prefix}-replica-${count.index + 1}-lag"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 2
  metric_name         = "ReplicaLag"
  namespace           = "AWS/RDS"
  period              = 60
  statistic           = "Average"
  threshold           = 3000 # 3 seconds
  alarm_description   = "Replica lag > 3s"

  dimensions = {
    DBInstanceIdentifier = var.rds_replica_ids[count.index]
  }

  tags = var.tags
}

resource "aws_cloudwatch_metric_alarm" "redis_cpu" {
  alarm_name          = "${var.name_prefix}-redis-cpu-high"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 2
  metric_name         = "CPUUtilization"
  namespace           = "AWS/ElastiCache"
  period              = 300
  statistic           = "Average"
  threshold           = 75
  alarm_description   = "Redis CPU > 75%"

  dimensions = {
    CacheClusterId = "${var.redis_replication_group_id}-001"
  }

  tags = var.tags
}
