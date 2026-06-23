data "aws_availability_zones" "available" {
  state = "available"
}

locals {
  # "-{suffix}" appended to the end of every resource name (empty when unset).
  sfx = var.suffix == "" ? "" : "-${var.suffix}"

  # Resolve AZs: explicit list wins, otherwise take the first az_count AZs.
  azs = length(var.availability_zones) > 0 ? var.availability_zones : slice(data.aws_availability_zones.available.names, 0, var.az_count)

  az_indexes = range(length(local.azs))

  # Derive subnet CIDRs from the VPC CIDR when not provided explicitly.
  # /16 VPC -> /24 subnets, offset by tier so the three tiers never overlap.
  public_cidrs = length(var.public_subnet_cidrs) > 0 ? var.public_subnet_cidrs : [
    for i in local.az_indexes : cidrsubnet(var.vpc_cidr, 8, i)
  ]
  private_app_cidrs = length(var.private_app_subnet_cidrs) > 0 ? var.private_app_subnet_cidrs : [
    for i in local.az_indexes : cidrsubnet(var.vpc_cidr, 8, i + 10)
  ]
  private_eks_cidrs = length(var.private_eks_subnet_cidrs) > 0 ? var.private_eks_subnet_cidrs : [
    for i in local.az_indexes : cidrsubnet(var.vpc_cidr, 8, i + 20)
  ]
  management_cidrs = length(var.management_subnet_cidrs) > 0 ? var.management_subnet_cidrs : [
    for i in local.az_indexes : cidrsubnet(var.vpc_cidr, 8, i + 30)
  ]

  # Number of NAT gateways to create.
  nat_gateway_count = var.enable_nat_gateway ? (var.single_nat_gateway ? 1 : length(local.azs)) : 0
}

#############################
# VPC + Internet Gateway
#############################

resource "aws_vpc" "this" {
  cidr_block           = var.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = merge(var.tags, { Name = "${var.name_prefix}-vpc${local.sfx}" })
}

resource "aws_internet_gateway" "this" {
  vpc_id = aws_vpc.this.id

  tags = merge(var.tags, { Name = "${var.name_prefix}-igw${local.sfx}" })
}

#############################
# Subnets
#############################

resource "aws_subnet" "public" {
  count = length(local.azs)

  vpc_id                  = aws_vpc.this.id
  cidr_block              = local.public_cidrs[count.index]
  availability_zone       = local.azs[count.index]
  map_public_ip_on_launch = var.map_public_ip_on_launch

  tags = merge(var.tags, {
    Name                     = "${var.name_prefix}-public-${local.azs[count.index]}${local.sfx}"
    Tier                     = "public"
    "kubernetes.io/role/elb" = "1"
  })
}

resource "aws_subnet" "private_app" {
  count = length(local.azs)

  vpc_id                  = aws_vpc.this.id
  cidr_block              = local.private_app_cidrs[count.index]
  availability_zone       = local.azs[count.index]
  map_public_ip_on_launch = false

  tags = merge(var.tags, {
    Name = "${var.name_prefix}-private-app-${local.azs[count.index]}${local.sfx}"
    Tier = "private-app"
  })
}

resource "aws_subnet" "private_eks" {
  count = length(local.azs)

  vpc_id                  = aws_vpc.this.id
  cidr_block              = local.private_eks_cidrs[count.index]
  availability_zone       = local.azs[count.index]
  map_public_ip_on_launch = false

  tags = merge(var.tags, var.eks_subnet_tags, {
    Name = "${var.name_prefix}-private-eks-${local.azs[count.index]}${local.sfx}"
    Tier = "private-eks"
  })
}

resource "aws_subnet" "management" {
  count = length(local.azs)

  vpc_id                  = aws_vpc.this.id
  cidr_block              = local.management_cidrs[count.index]
  availability_zone       = local.azs[count.index]
  map_public_ip_on_launch = false

  tags = merge(var.tags, {
    Name = "${var.name_prefix}-management-${local.azs[count.index]}${local.sfx}"
    Tier = "management"
  })
}

#############################
# NAT Gateways (one per AZ for HA, or a single shared one)
#############################

resource "aws_eip" "nat" {
  count  = local.nat_gateway_count
  domain = "vpc"

  tags = merge(var.tags, { Name = "${var.name_prefix}-nat-eip-${count.index}${local.sfx}" })

  depends_on = [aws_internet_gateway.this]
}

resource "aws_nat_gateway" "this" {
  count = local.nat_gateway_count

  allocation_id = aws_eip.nat[count.index].id
  subnet_id     = aws_subnet.public[count.index].id

  tags = merge(var.tags, { Name = "${var.name_prefix}-nat-${count.index}${local.sfx}" })

  depends_on = [aws_internet_gateway.this]
}

#############################
# Route tables
#############################

# Single public route table -> IGW, shared by both public subnets.
resource "aws_route_table" "public" {
  vpc_id = aws_vpc.this.id

  tags = merge(var.tags, { Name = "${var.name_prefix}-rt-public${local.sfx}" })
}

resource "aws_route" "public_internet" {
  route_table_id         = aws_route_table.public.id
  destination_cidr_block = "0.0.0.0/0"
  gateway_id             = aws_internet_gateway.this.id
}

resource "aws_route_table_association" "public" {
  count          = length(aws_subnet.public)
  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public.id
}

# One private route table per AZ so each AZ uses its AZ-local NAT gateway.
resource "aws_route_table" "private" {
  count  = length(local.azs)
  vpc_id = aws_vpc.this.id

  tags = merge(var.tags, { Name = "${var.name_prefix}-rt-private-${local.azs[count.index]}${local.sfx}" })
}

resource "aws_route" "private_nat" {
  count = var.enable_nat_gateway ? length(local.azs) : 0

  route_table_id         = aws_route_table.private[count.index].id
  destination_cidr_block = "0.0.0.0/0"
  # With a single shared NAT gateway every AZ routes through index 0.
  nat_gateway_id = var.single_nat_gateway ? aws_nat_gateway.this[0].id : aws_nat_gateway.this[count.index].id
}

resource "aws_route_table_association" "private_app" {
  count          = length(aws_subnet.private_app)
  subnet_id      = aws_subnet.private_app[count.index].id
  route_table_id = aws_route_table.private[count.index].id
}

resource "aws_route_table_association" "private_eks" {
  count          = length(aws_subnet.private_eks)
  subnet_id      = aws_subnet.private_eks[count.index].id
  route_table_id = aws_route_table.private[count.index].id
}

resource "aws_route_table_association" "management" {
  count          = length(aws_subnet.management)
  subnet_id      = aws_subnet.management[count.index].id
  route_table_id = aws_route_table.private[count.index].id
}

#############################
# VPC Endpoints (keep SSM/EC2/S3 traffic off the public internet)
#############################

# Security group allowing HTTPS from within the VPC to the interface endpoints.
resource "aws_security_group" "endpoints" {
  name        = "${var.name_prefix}-vpce-sg${local.sfx}"
  description = "Allow HTTPS from the VPC to interface VPC endpoints"
  vpc_id      = aws_vpc.this.id

  ingress {
    description = "HTTPS from within the VPC"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = [var.vpc_cidr]
  }

  egress {
    description = "Allow all egress"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(var.tags, { Name = "${var.name_prefix}-vpce-sg${local.sfx}" })
}

resource "aws_vpc_endpoint" "interface" {
  for_each = toset(var.interface_endpoints)

  vpc_id              = aws_vpc.this.id
  service_name        = "com.amazonaws.${var.aws_region}.${each.value}"
  vpc_endpoint_type   = "Interface"
  subnet_ids          = aws_subnet.private_app[*].id
  security_group_ids  = [aws_security_group.endpoints.id]
  private_dns_enabled = true

  tags = merge(var.tags, { Name = "${var.name_prefix}-vpce-${each.value}${local.sfx}" })
}

resource "aws_vpc_endpoint" "s3" {
  count = var.enable_s3_gateway_endpoint ? 1 : 0

  vpc_id            = aws_vpc.this.id
  service_name      = "com.amazonaws.${var.aws_region}.s3"
  vpc_endpoint_type = "Gateway"
  route_table_ids   = concat([aws_route_table.public.id], aws_route_table.private[*].id)

  tags = merge(var.tags, { Name = "${var.name_prefix}-vpce-s3${local.sfx}" })
}
