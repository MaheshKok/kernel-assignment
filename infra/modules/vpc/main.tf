# ============================================================================
# VPC MODULE
# ============================================================================
# Creates VPC with public/private subnets, NAT gateways, and route tables
# ============================================================================

data "aws_availability_zones" "available" {
  state = "available"
}

resource "aws_vpc" "main" {
  cidr_block           = var.vpc_cidr
  enable_dns_hostnames = true
  enable_dns_support   = true
  tags = merge(
    var.tags,
    { Name = "${var.name_prefix}-vpc" }
  )
}

resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id
  tags = merge(
    var.tags,
    { Name = "${var.name_prefix}-igw" }
  )
}

# ============================================================================
# SUBNETS
# ============================================================================

resource "aws_subnet" "public" {
  count                   = 3
  vpc_id                  = aws_vpc.main.id
  cidr_block              = cidrsubnet(aws_vpc.main.cidr_block, 8, count.index)
  availability_zone       = data.aws_availability_zones.available.names[count.index]
  map_public_ip_on_launch = true
  tags = merge(
    var.tags,
    { Name = "${var.name_prefix}-public-${count.index + 1}" }
  )
}

resource "aws_subnet" "private_db" {
  count             = 3
  vpc_id            = aws_vpc.main.id
  cidr_block        = cidrsubnet(aws_vpc.main.cidr_block, 8, count.index + 10)
  availability_zone = data.aws_availability_zones.available.names[count.index]
  tags = merge(
    var.tags,
    { Name = "${var.name_prefix}-private-db-${count.index + 1}" }
  )
}

resource "aws_subnet" "private_cache" {
  count             = 3
  vpc_id            = aws_vpc.main.id
  cidr_block        = cidrsubnet(aws_vpc.main.cidr_block, 8, count.index + 20)
  availability_zone = data.aws_availability_zones.available.names[count.index]
  tags = merge(
    var.tags,
    { Name = "${var.name_prefix}-private-cache-${count.index + 1}" }
  )
}

# ============================================================================
# NAT GATEWAYS
# ============================================================================

resource "aws_eip" "nat" {
  count  = var.nat_gateway_count
  domain = "vpc"
  tags = merge(
    var.tags,
    { Name = "${var.name_prefix}-nat-eip-${count.index + 1}" }
  )
}

resource "aws_nat_gateway" "main" {
  count         = var.nat_gateway_count
  allocation_id = aws_eip.nat[count.index].id
  subnet_id     = aws_subnet.public[count.index].id
  tags = merge(
    var.tags,
    { Name = "${var.name_prefix}-nat-${count.index + 1}" }
  )
}

# ============================================================================
# ROUTE TABLES
# ============================================================================

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id
  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.main.id
  }
  tags = merge(
    var.tags,
    { Name = "${var.name_prefix}-public-rt" }
  )
}

resource "aws_route_table" "private" {
  count  = var.nat_gateway_count
  vpc_id = aws_vpc.main.id
  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.main[count.index].id
  }
  tags = merge(
    var.tags,
    { Name = "${var.name_prefix}-private-rt-${count.index + 1}" }
  )
}

# ============================================================================
# ROUTE TABLE ASSOCIATIONS
# ============================================================================

resource "aws_route_table_association" "public" {
  count          = length(aws_subnet.public)
  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public.id
}

resource "aws_route_table_association" "private_db" {
  count          = length(aws_subnet.private_db)
  subnet_id      = aws_subnet.private_db[count.index].id
  route_table_id = aws_route_table.private[var.nat_gateway_count > 1 ? count.index : 0].id
}

resource "aws_route_table_association" "private_cache" {
  count          = length(aws_subnet.private_cache)
  subnet_id      = aws_subnet.private_cache[count.index].id
  route_table_id = aws_route_table.private[var.nat_gateway_count > 1 ? count.index : 0].id
}
