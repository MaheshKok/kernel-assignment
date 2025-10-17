output "app_security_group_id" {
  description = "Application security group ID"
  value       = aws_security_group.app.id
}

output "rds_security_group_id" {
  description = "RDS security group ID"
  value       = aws_security_group.rds.id
}

output "redis_security_group_id" {
  description = "Redis security group ID"
  value       = aws_security_group.redis.id
}

output "redshift_security_group_id" {
  description = "Redshift security group ID"
  value       = aws_security_group.redshift.id
}
