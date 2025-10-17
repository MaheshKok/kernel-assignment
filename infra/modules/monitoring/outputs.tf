output "rds_cpu_alarm_arn" {
  description = "RDS CPU alarm ARN"
  value       = aws_cloudwatch_metric_alarm.rds_cpu.arn
}

output "rds_storage_alarm_arn" {
  description = "RDS storage alarm ARN"
  value       = aws_cloudwatch_metric_alarm.rds_storage.arn
}

output "redis_cpu_alarm_arn" {
  description = "Redis CPU alarm ARN"
  value       = aws_cloudwatch_metric_alarm.redis_cpu.arn
}
