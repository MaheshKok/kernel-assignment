# ============================================================================
# SECURITY GROUPS MODULE
# ============================================================================
# Creates security groups for RDS, Redis, Redshift, and application
# ============================================================================
#
# Data Flow & Connectivity:
#   App (ECS/EKS)
#     |
#     ├──> RDS PostgreSQL (port 5432)
#     |      └─> Debezium reads WAL for CDC
#     |
#     ├──> Redis Cache (port 6379)
#     |      └─> Hot attribute caching
#     |
#     └──> Redshift (port 5439)
#            └─> Analytics query execution
#
# Note: Redshift does NOT connect back to RDS
#       (Data flows via Kafka → Flink → Redshift)
# ============================================================================

resource "aws_security_group" "app" {
  name_prefix = "${var.name_prefix}-app-"
  vpc_id      = var.vpc_id

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(
    var.tags,
    { Name = "${var.name_prefix}-app-sg" }
  )

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_security_group" "rds" {
  name_prefix = "${var.name_prefix}-rds-"
  vpc_id      = var.vpc_id

  ingress {
    from_port       = 5432
    to_port         = 5432
    protocol        = "tcp"
    security_groups = [aws_security_group.app.id]
    description     = "PostgreSQL from app (Debezium CDC, application queries)"
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(
    var.tags,
    { Name = "${var.name_prefix}-rds-sg" }
  )

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_security_group" "redis" {
  name_prefix = "${var.name_prefix}-redis-"
  vpc_id      = var.vpc_id

  ingress {
    from_port       = 6379
    to_port         = 6379
    protocol        = "tcp"
    security_groups = [aws_security_group.app.id]
    description     = "Redis from app"
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(
    var.tags,
    { Name = "${var.name_prefix}-redis-sg" }
  )

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_security_group" "redshift" {
  name_prefix = "${var.name_prefix}-redshift-"
  vpc_id      = var.vpc_id

  ingress {
    from_port       = 5439
    to_port         = 5439
    protocol        = "tcp"
    security_groups = [aws_security_group.app.id]
    description     = "Redshift from app"
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(
    var.tags,
    { Name = "${var.name_prefix}-redshift-sg" }
  )

  lifecycle {
    create_before_destroy = true
  }
}
