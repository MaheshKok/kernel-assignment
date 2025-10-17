# ============================================================================
# REDSHIFT MODULE
# ============================================================================

resource "aws_redshift_subnet_group" "main" {
  name       = "${var.name_prefix}-redshift-subnet"
  subnet_ids = var.subnet_ids
  tags = merge(
    var.tags,
    { Name = "${var.name_prefix}-redshift-subnet" }
  )
}

resource "aws_redshift_cluster" "main" {
  cluster_identifier = "${var.name_prefix}-redshift"

  database_name   = var.database_name
  master_username = var.master_username
  master_password = var.master_password

  node_type       = var.node_type
  cluster_type    = var.number_of_nodes > 1 ? "multi-node" : "single-node"
  number_of_nodes = var.number_of_nodes

  cluster_subnet_group_name = aws_redshift_subnet_group.main.name
  vpc_security_group_ids    = var.security_group_ids

  encrypted                           = true
  enhanced_vpc_routing                = true
  automated_snapshot_retention_period = var.snapshot_retention_period

  skip_final_snapshot       = !var.create_final_snapshot
  final_snapshot_identifier = var.create_final_snapshot ? "${var.name_prefix}-redshift-final-${formatdate("YYYYMMDD-hhmm", timestamp())}" : null

  tags = merge(
    var.tags,
    { Name = "${var.name_prefix}-redshift" }
  )
}
