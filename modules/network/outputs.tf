output "vpc_id" {
  description = "ID of the VPC."
  value       = aws_vpc.this.id
}

output "vpc_cidr" {
  description = "CIDR block of the VPC."
  value       = aws_vpc.this.cidr_block
}

output "availability_zones" {
  description = "AZs the network spans."
  value       = local.azs
}

output "internet_gateway_id" {
  description = "ID of the Internet Gateway."
  value       = aws_internet_gateway.this.id
}

output "public_subnet_ids" {
  description = "IDs of the public subnets (host the bastion and NAT gateways)."
  value       = aws_subnet.public[*].id
}

output "public_subnet_cidrs" {
  description = "CIDR blocks of the public subnets."
  value       = aws_subnet.public[*].cidr_block
}

output "private_app_subnet_ids" {
  description = "IDs of the private EC2 (application) subnets."
  value       = aws_subnet.private_app[*].id
}

output "private_app_subnet_cidrs" {
  description = "CIDR blocks of the private EC2 subnets."
  value       = aws_subnet.private_app[*].cidr_block
}

output "private_eks_subnet_ids" {
  description = "IDs of the private EKS subnets."
  value       = aws_subnet.private_eks[*].id
}

output "private_eks_subnet_cidrs" {
  description = "CIDR blocks of the private EKS subnets."
  value       = aws_subnet.private_eks[*].cidr_block
}

output "management_subnet_ids" {
  description = "IDs of the private management subnets (host the Ansible control node)."
  value       = aws_subnet.management[*].id
}

output "management_subnet_cidrs" {
  description = "CIDR blocks of the private management subnets."
  value       = aws_subnet.management[*].cidr_block
}

# Map of subnet ID -> AZ for every subnet, for easy correlation.
output "subnet_azs" {
  description = "Map of subnet ID => availability zone (all tiers)."
  value = merge(
    { for s in aws_subnet.public : s.id => s.availability_zone },
    { for s in aws_subnet.private_app : s.id => s.availability_zone },
    { for s in aws_subnet.private_eks : s.id => s.availability_zone },
    { for s in aws_subnet.management : s.id => s.availability_zone },
  )
}

output "nat_gateway_ids" {
  description = "IDs of the NAT gateways."
  value       = aws_nat_gateway.this[*].id
}

output "nat_eip_ids" {
  description = "Allocation IDs of the NAT gateway Elastic IPs."
  value       = aws_eip.nat[*].id
}

output "nat_eip_public_ips" {
  description = "Public IPs of the NAT gateways."
  value       = aws_eip.nat[*].public_ip
}

output "public_route_table_id" {
  description = "ID of the public route table."
  value       = aws_route_table.public.id
}

output "private_route_table_ids" {
  description = "IDs of the per-AZ private route tables."
  value       = aws_route_table.private[*].id
}

output "endpoint_security_group_id" {
  description = "Security group ID protecting the interface VPC endpoints."
  value       = aws_security_group.endpoints.id
}

output "interface_endpoint_ids" {
  description = "Map of service name -> interface VPC endpoint ID."
  value       = { for k, v in aws_vpc_endpoint.interface : k => v.id }
}

output "s3_endpoint_id" {
  description = "ID of the S3 gateway VPC endpoint (null when disabled)."
  value       = try(aws_vpc_endpoint.s3[0].id, null)
}

output "vpc_endpoint_ids" {
  description = "All VPC endpoint IDs (interface + gateway)."
  value       = concat([for v in aws_vpc_endpoint.interface : v.id], aws_vpc_endpoint.s3[*].id)
}
