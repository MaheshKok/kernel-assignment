# ============================================================================
# IAM MODULE
# ============================================================================

resource "aws_iam_role" "rds_monitoring" {
  count = var.enable_rds_monitoring ? 1 : 0
  name  = "${var.name_prefix}-rds-monitoring"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action = "sts:AssumeRole"
      Effect = "Allow"
      Principal = {
        Service = "monitoring.rds.amazonaws.com"
      }
    }]
  })

  tags = var.tags
}

resource "aws_iam_role_policy_attachment" "rds_monitoring" {
  count      = var.enable_rds_monitoring ? 1 : 0
  role       = aws_iam_role.rds_monitoring[0].name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonRDSEnhancedMonitoringRole"
}

resource "aws_iam_role" "rds_proxy" {
  name = "${var.name_prefix}-rds-proxy"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action = "sts:AssumeRole"
      Effect = "Allow"
      Principal = {
        Service = "rds.amazonaws.com"
      }
    }]
  })

  tags = var.tags
}

resource "aws_iam_role_policy" "rds_proxy_secrets" {
  name = "rds-proxy-secrets"
  role = aws_iam_role.rds_proxy.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action   = ["secretsmanager:GetSecretValue"]
      Effect   = "Allow"
      Resource = var.rds_secret_arn
    }]
  })
}
