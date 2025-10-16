# Terraform Configuration for EAV PostgreSQL Infrastructure
# AWS RDS PostgreSQL + Redshift + VPC Configuration

terraform {
  required_version = ">= 1.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

# Variables for environment-specific configuration
variable "environment" {
  description = "Environment name (dev/staging/prod)"
  type        = string
  validation {
    condition     = contains(["dev", "staging", "prod"], var.environment)
    error_message = "Environment must be dev, staging, or prod."
  }
}

variable "region" {
  description = "AWS region"
  type        = string
  default     = "us-east-1"
}

variable "project_name" {
  description = "Project name for resource naming"
  type        = string
  default     = "eav-platform"
}

variable "database_master_password" {
  description = "Master password for RDS instance"
  type        = string
  sensitive   = true
}

variable "redshift_master_password" {
  description = "Master password for Redshift cluster"
  type        = string
  sensitive   = true
}

# Local variables for environment-specific settings
locals {
  common_tags = {
    Environment = var.environment
    Project     = var.project_name
    ManagedBy   = "Terraform"
    CreatedAt   = timestamp()
  }

  # Environment-specific configurations
  env_config = {
    dev = {
      rds_instance_class      = "db.t3.large"
      rds_allocated_storage   = 100
      rds_max_allocated_storage = 200
      rds_backup_retention    = 1
      rds_multi_az           = false
      redshift_node_type     = "dc2.large"
      redshift_nodes         = 1
      vpc_cidr              = "10.0.0.0/16"
    }
    staging = {
      rds_instance_class      = "db.r6g.xlarge"
      rds_allocated_storage   = 500
      rds_max_allocated_storage = 1000
      rds_backup_retention    = 7
      rds_multi_az           = true
      redshift_node_type     = "dc2.large"
      redshift_nodes         = 2
      vpc_cidr              = "10.1.0.0/16"
    }
    prod = {
      rds_instance_class      = "db.r6g.4xlarge"
      rds_allocated_storage   = 1000
      rds_max_allocated_storage = 10000
      rds_backup_retention    = 30
      rds_multi_az           = true
      redshift_node_type     = "ra3.4xlarge"
      redshift_nodes         = 3
      vpc_cidr              = "10.2.0.0/16"
    }
  }

  current_env = local.env_config[var.environment]
}

# Provider configuration
provider "aws" {
  region = var.region
}

# VPC Configuration
resource "aws_vpc" "main" {
  cidr_block           = local.current_env.vpc_cidr
  enable_dns_hostnames = true
  enable_dns_support   = true

  tags = merge(local.common_tags, {
    Name = "${var.project_name}-${var.environment}-vpc"
  })
}

# Internet Gateway
resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id

  tags = merge(local.common_tags, {
    Name = "${var.project_name}-${var.environment}-igw"
  })
}

# Public Subnets (for NAT gateways)
resource "aws_subnet" "public" {
  count             = 2
  vpc_id            = aws_vpc.main.id
  cidr_block        = cidrsubnet(aws_vpc.main.cidr_block, 8, count.index)
  availability_zone = data.aws_availability_zones.available.names[count.index]

  map_public_ip_on_launch = true

  tags = merge(local.common_tags, {
    Name = "${var.project_name}-${var.environment}-public-${count.index + 1}"
    Type = "Public"
  })
}

# Private Subnets for RDS
resource "aws_subnet" "private_rds" {
  count             = 2
  vpc_id            = aws_vpc.main.id
  cidr_block        = cidrsubnet(aws_vpc.main.cidr_block, 8, count.index + 10)
  availability_zone = data.aws_availability_zones.available.names[count.index]

  tags = merge(local.common_tags, {
    Name = "${var.project_name}-${var.environment}-private-rds-${count.index + 1}"
    Type = "Private-RDS"
  })
}

# Private Subnets for Redshift
resource "aws_subnet" "private_redshift" {
  count             = 2
  vpc_id            = aws_vpc.main.id
  cidr_block        = cidrsubnet(aws_vpc.main.cidr_block, 8, count.index + 20)
  availability_zone = data.aws_availability_zones.available.names[count.index]

  tags = merge(local.common_tags, {
    Name = "${var.project_name}-${var.environment}-private-redshift-${count.index + 1}"
    Type = "Private-Redshift"
  })
}

# NAT Gateway
resource "aws_eip" "nat" {
  count  = var.environment == "prod" ? 2 : 1
  domain = "vpc"

  tags = merge(local.common_tags, {
    Name = "${var.project_name}-${var.environment}-nat-eip-${count.index + 1}"
  })
}

resource "aws_nat_gateway" "main" {
  count         = var.environment == "prod" ? 2 : 1
  allocation_id = aws_eip.nat[count.index].id
  subnet_id     = aws_subnet.public[count.index].id

  tags = merge(local.common_tags, {
    Name = "${var.project_name}-${var.environment}-nat-${count.index + 1}"
  })
}

# Route Tables
resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.main.id
  }

  tags = merge(local.common_tags, {
    Name = "${var.project_name}-${var.environment}-public-rt"
  })
}

resource "aws_route_table" "private" {
  count  = var.environment == "prod" ? 2 : 1
  vpc_id = aws_vpc.main.id

  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.main[count.index].id
  }

  tags = merge(local.common_tags, {
    Name = "${var.project_name}-${var.environment}-private-rt-${count.index + 1}"
  })
}

# Route Table Associations
resource "aws_route_table_association" "public" {
  count          = length(aws_subnet.public)
  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public.id
}

resource "aws_route_table_association" "private_rds" {
  count          = length(aws_subnet.private_rds)
  subnet_id      = aws_subnet.private_rds[count.index].id
  route_table_id = aws_route_table.private[var.environment == "prod" ? count.index : 0].id
}

resource "aws_route_table_association" "private_redshift" {
  count          = length(aws_subnet.private_redshift)
  subnet_id      = aws_subnet.private_redshift[count.index].id
  route_table_id = aws_route_table.private[var.environment == "prod" ? count.index : 0].id
}

# Security Groups
resource "aws_security_group" "rds" {
  name_prefix = "${var.project_name}-${var.environment}-rds-"
  vpc_id      = aws_vpc.main.id

  ingress {
    from_port       = 5432
    to_port         = 5432
    protocol        = "tcp"
    security_groups = [aws_security_group.app.id]
    description     = "PostgreSQL from application layer"
  }

  ingress {
    from_port       = 5432
    to_port         = 5432
    protocol        = "tcp"
    security_groups = [aws_security_group.redshift.id]
    description     = "PostgreSQL from Redshift for replication"
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
    description = "Allow all outbound"
  }

  tags = merge(local.common_tags, {
    Name = "${var.project_name}-${var.environment}-rds-sg"
  })

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_security_group" "redshift" {
  name_prefix = "${var.project_name}-${var.environment}-redshift-"
  vpc_id      = aws_vpc.main.id

  ingress {
    from_port       = 5439
    to_port         = 5439
    protocol        = "tcp"
    security_groups = [aws_security_group.app.id]
    description     = "Redshift from application layer"
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
    description = "Allow all outbound"
  }

  tags = merge(local.common_tags, {
    Name = "${var.project_name}-${var.environment}-redshift-sg"
  })

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_security_group" "app" {
  name_prefix = "${var.project_name}-${var.environment}-app-"
  vpc_id      = aws_vpc.main.id

  # This would typically include ingress rules from ALB or specific IPs
  # Simplified for this example
  
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
    description = "Allow all outbound"
  }

  tags = merge(local.common_tags, {
    Name = "${var.project_name}-${var.environment}-app-sg"
  })

  lifecycle {
    create_before_destroy = true
  }
}

# RDS Subnet Group
resource "aws_db_subnet_group" "rds" {
  name       = "${var.project_name}-${var.environment}-rds-subnet-group"
  subnet_ids = aws_subnet.private_rds[*].id

  tags = merge(local.common_tags, {
    Name = "${var.project_name}-${var.environment}-rds-subnet-group"
  })
}

# RDS Parameter Group for PostgreSQL
resource "aws_db_parameter_group" "postgres" {
  name_prefix = "${var.project_name}-${var.environment}-postgres-"
  family      = "postgres15"

  # Optimizations for EAV workload
  parameter {
    name  = "shared_preload_libraries"
    value = "pg_stat_statements,pg_partman_bgw,pglogical"
  }

  parameter {
    name  = "max_connections"
    value = var.environment == "prod" ? "1000" : "200"
  }

  parameter {
    name  = "work_mem"
    value = var.environment == "prod" ? "16384" : "4096" # in KB
  }

  parameter {
    name  = "maintenance_work_mem"
    value = var.environment == "prod" ? "2097152" : "524288" # in KB
  }

  parameter {
    name  = "effective_cache_size"
    value = var.environment == "prod" ? "48GB" : "4GB"
  }

  parameter {
    name  = "random_page_cost"
    value = "1.1" # SSD optimized
  }

  parameter {
    name  = "wal_level"
    value = "logical" # For logical replication
  }

  parameter {
    name  = "max_wal_senders"
    value = "10"
  }

  parameter {
    name  = "max_replication_slots"
    value = "10"
  }

  tags = merge(local.common_tags, {
    Name = "${var.project_name}-${var.environment}-postgres-params"
  })
}

# RDS PostgreSQL Instance
resource "aws_db_instance" "postgres" {
  identifier = "${var.project_name}-${var.environment}-postgres"

  engine         = "postgres"
  engine_version = "15.4"
  
  instance_class        = local.current_env.rds_instance_class
  allocated_storage     = local.current_env.rds_allocated_storage
  max_allocated_storage = local.current_env.rds_max_allocated_storage
  storage_type          = "gp3"
  storage_encrypted     = true
  iops                  = var.environment == "prod" ? 12000 : 3000

  db_name  = "eav_db"
  username = "eav_admin"
  password = var.database_master_password

  db_subnet_group_name   = aws_db_subnet_group.rds.name
  vpc_security_group_ids = [aws_security_group.rds.id]
  parameter_group_name   = aws_db_parameter_group.postgres.name

  multi_az               = local.current_env.rds_multi_az
  backup_retention_period = local.current_env.rds_backup_retention
  backup_window          = "03:00-04:00"
  maintenance_window     = "sun:04:00-sun:05:00"

  enabled_cloudwatch_logs_exports = ["postgresql"]
  
  performance_insights_enabled    = var.environment == "prod"
  performance_insights_retention_period = var.environment == "prod" ? 731 : 0

  deletion_protection = var.environment == "prod"
  skip_final_snapshot = var.environment != "prod"
  final_snapshot_identifier = var.environment == "prod" ? "${var.project_name}-${var.environment}-final-snapshot-${formatdate("YYYY-MM-DD-hhmm", timestamp())}" : null

  tags = merge(local.common_tags, {
    Name = "${var.project_name}-${var.environment}-postgres"
  })
}

# RDS Read Replica (for prod environment)
resource "aws_db_instance" "postgres_replica" {
  count = var.environment == "prod" ? 2 : 0

  identifier = "${var.project_name}-${var.environment}-postgres-replica-${count.index + 1}"
  
  replicate_source_db = aws_db_instance.postgres.identifier
  
  instance_class    = local.current_env.rds_instance_class
  storage_encrypted = true

  skip_final_snapshot = true

  tags = merge(local.common_tags, {
    Name = "${var.project_name}-${var.environment}-postgres-replica-${count.index + 1}"
    Type = "ReadReplica"
  })
}

# Redshift Subnet Group
resource "aws_redshift_subnet_group" "main" {
  name       = "${var.project_name}-${var.environment}-redshift-subnet-group"
  subnet_ids = aws_subnet.private_redshift[*].id

  tags = merge(local.common_tags, {
    Name = "${var.project_name}-${var.environment}-redshift-subnet-group"
  })
}

# Redshift Parameter Group
resource "aws_redshift_parameter_group" "main" {
  name   = "${var.project_name}-${var.environment}-redshift-params"
  family = "redshift-1.0"

  parameter {
    name  = "enable_user_activity_logging"
    value = "true"
  }

  parameter {
    name  = "require_ssl"
    value = "true"
  }

  parameter {
    name  = "max_concurrency_scaling_clusters"
    value = var.environment == "prod" ? "3" : "1"
  }
}

# Redshift Cluster
resource "aws_redshift_cluster" "main" {
  cluster_identifier = "${var.project_name}-${var.environment}-redshift"

  database_name = "eav_analytics"
  master_username = "eav_admin"
  master_password = var.redshift_master_password

  node_type       = local.current_env.redshift_node_type
  cluster_type    = local.current_env.redshift_nodes > 1 ? "multi-node" : "single-node"
  number_of_nodes = local.current_env.redshift_nodes

  cluster_subnet_group_name    = aws_redshift_subnet_group.main.name
  vpc_security_group_ids       = [aws_security_group.redshift.id]
  cluster_parameter_group_name = aws_redshift_parameter_group.main.name

  encrypted                        = true
  enhanced_vpc_routing             = true
  publicly_accessible              = false
  automated_snapshot_retention_period = var.environment == "prod" ? 35 : 1
  
  skip_final_snapshot       = var.environment != "prod"
  final_snapshot_identifier = var.environment == "prod" ? "${var.project_name}-${var.environment}-redshift-final-${formatdate("YYYY-MM-DD-hhmm", timestamp())}" : null

  tags = merge(local.common_tags, {
    Name = "${var.project_name}-${var.environment}-redshift"
  })
}

# Data source for availability zones
data "aws_availability_zones" "available" {
  state = "available"
}

# Outputs
output "rds_endpoint" {
  description = "RDS instance endpoint"
  value       = aws_db_instance.postgres.endpoint
}

output "rds_read_replica_endpoints" {
  description = "RDS read replica endpoints"
  value       = [for replica in aws_db_instance.postgres_replica : replica.endpoint]
}

output "redshift_endpoint" {
  description = "Redshift cluster endpoint"
  value       = aws_redshift_cluster.main.endpoint
}

output "vpc_id" {
  description = "VPC ID"
  value       = aws_vpc.main.id
}

output "rds_security_group_id" {
  description = "RDS security group ID"
  value       = aws_security_group.rds.id
}

output "redshift_security_group_id" {
  description = "Redshift security group ID"
  value       = aws_security_group.redshift.id
}