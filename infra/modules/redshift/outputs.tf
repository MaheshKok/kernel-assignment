output "redshift_endpoint" {
  description = "Redshift cluster endpoint"
  value       = aws_redshift_cluster.main.endpoint
}

output "redshift_cluster_id" {
  description = "Redshift cluster ID"
  value       = aws_redshift_cluster.main.id
}
