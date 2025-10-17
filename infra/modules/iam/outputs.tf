output "rds_monitoring_role_arn" {
  description = "RDS monitoring role ARN"
  value       = var.enable_rds_monitoring ? aws_iam_role.rds_monitoring[0].arn : null
}

output "rds_proxy_role_arn" {
  description = "RDS Proxy role ARN"
  value       = aws_iam_role.rds_proxy.arn
}
