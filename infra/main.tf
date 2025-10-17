# ============================================================================
# EAV @ Scale: Modular Terraform Configuration
# ============================================================================
#
# USAGE:
#   terraform init
#   terraform plan -var environment=dev
#   terraform apply -var environment=prod
#
# ============================================================================

module "vpc" {
  source = "./modules/vpc"

  name_prefix       = local.name_prefix
  vpc_cidr          = local.current.vpc_cidr
  nat_gateway_count = local.current.nat_gateway_count
  tags              = local.common_tags
}

module "security_groups" {
  source = "./modules/security_groups"

  name_prefix = local.name_prefix
  vpc_id      = module.vpc.vpc_id
  tags        = local.common_tags
}

module "secrets" {
  source = "./modules/secrets"
  name_prefix          = local.name_prefix
  rds_secret_name      = var.rds_secret_name
  redshift_secret_name = var.redshift_secret_name
  tags                 = local.common_tags
}


module "iam" {
  source = "./modules/iam"

  name_prefix           = local.name_prefix
  enable_rds_monitoring = local.current.enable_enhanced_monitoring
  rds_secret_arn        = module.secrets.rds_secret_arn
  tags                  = local.common_tags
}

module "rds" {
  source = "./modules/rds"

  name_prefix                = local.name_prefix
  subnet_ids                 = module.vpc.private_db_subnet_ids
  security_group_ids         = [module.security_groups.rds_security_group_id]
  instance_class             = local.current.rds_instance
  allocated_storage          = local.current.rds_storage
  iops                       = local.current.rds_iops
  storage_throughput         = local.current.rds_storage_throughput
  master_username            = module.secrets.rds_username
  master_password            = module.secrets.rds_password
  multi_az                   = local.current.rds_multi_az
  replica_count              = local.current.rds_replicas
  backup_retention_period    = local.current.backup_retention
  enable_enhanced_monitoring = local.current.enable_enhanced_monitoring
  monitoring_role_arn        = module.iam.rds_monitoring_role_arn
  deletion_protection        = local.current.deletion_protection
  max_connections            = local.current.rds_max_connections
  proxy_secret_arn           = module.secrets.rds_secret_arn
  proxy_role_arn             = module.iam.rds_proxy_role_arn
  tags                       = local.common_tags
}

module "elasticache" {
  source = "./modules/elasticache"

  name_prefix              = local.name_prefix
  subnet_ids               = module.vpc.private_cache_subnet_ids
  security_group_ids       = [module.security_groups.redis_security_group_id]
  node_type                = local.current.redis_node_type
  num_cache_clusters       = local.current.redis_nodes
  snapshot_retention_limit = local.current.redis_snapshot_retention
  tags                     = local.common_tags
}

module "redshift" {
  source = "./modules/redshift"

  name_prefix                = local.name_prefix
  subnet_ids                 = module.vpc.private_db_subnet_ids
  security_group_ids         = [module.security_groups.redshift_security_group_id]
  master_username            = module.secrets.redshift_username
  master_password            = module.secrets.redshift_password
  node_type                  = local.current.redshift_node_type
  number_of_nodes            = local.current.redshift_nodes
  snapshot_retention_period  = local.current.redshift_snapshot_retention
  create_final_snapshot      = local.current.deletion_protection
  tags                       = local.common_tags
}

module "monitoring" {
  source = "./modules/monitoring"

  name_prefix                 = local.name_prefix
  rds_instance_id             = module.rds.db_instance_id
  rds_replica_ids             = module.rds.replica_instance_ids
  redis_replication_group_id  = module.elasticache.redis_replication_group_id
  tags                        = local.common_tags
}
