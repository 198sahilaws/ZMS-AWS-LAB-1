#############################
# Network
#############################

output "vpc_id" {
  description = "ID of the VPC."
  value       = module.network.vpc_id
}

output "vpc_cidr" {
  description = "CIDR block of the VPC."
  value       = module.network.vpc_cidr
}

output "availability_zones" {
  description = "Availability zones the stack spans."
  value       = module.network.availability_zones
}

output "public_subnet_ids" {
  description = "Public subnet IDs."
  value       = module.network.public_subnet_ids
}

output "public_subnet_cidrs" {
  description = "Public subnet CIDR blocks."
  value       = module.network.public_subnet_cidrs
}

output "private_app_subnet_ids" {
  description = "Private EC2 subnet IDs."
  value       = module.network.private_app_subnet_ids
}

output "private_app_subnet_cidrs" {
  description = "Private EC2 subnet CIDR blocks."
  value       = module.network.private_app_subnet_cidrs
}

output "private_eks_subnet_ids" {
  description = "Private EKS subnet IDs."
  value       = module.network.private_eks_subnet_ids
}

output "private_eks_subnet_cidrs" {
  description = "Private EKS subnet CIDR blocks."
  value       = module.network.private_eks_subnet_cidrs
}

output "management_subnet_ids" {
  description = "Management subnet IDs (host the Ansible control node)."
  value       = module.network.management_subnet_ids
}

output "management_subnet_cidrs" {
  description = "Management subnet CIDR blocks."
  value       = module.network.management_subnet_cidrs
}

output "subnet_availability_zones" {
  description = "Map of subnet ID => availability zone (all tiers)."
  value       = module.network.subnet_azs
}

output "nat_gateway_ids" {
  description = "NAT gateway IDs."
  value       = module.network.nat_gateway_ids
}

output "nat_eip_ids" {
  description = "NAT gateway EIP allocation IDs."
  value       = module.network.nat_eip_ids
}

output "public_route_table_id" {
  description = "Public route table ID."
  value       = module.network.public_route_table_id
}

output "private_route_table_ids" {
  description = "Per-AZ private route table IDs."
  value       = module.network.private_route_table_ids
}

output "vpc_endpoint_ids" {
  description = "All VPC endpoint IDs (interface + S3 gateway)."
  value       = module.network.vpc_endpoint_ids
}

#############################
# DNS
#############################

output "private_zone_id" {
  description = "Route 53 private hosted zone ID."
  value       = module.dns.zone_id
}

output "private_record_fqdns" {
  description = "Map of hostname => FQDN for every instance A record."
  value       = module.dns.record_fqdns
}

#############################
# Bastion
#############################

output "bastion_public_ip" {
  description = "Public IP of the bastion (SSH entry point)."
  value       = module.bastion.public_ip
}

output "bastion_public_dns" {
  description = "Public DNS of the bastion."
  value       = module.bastion.public_dns
}

output "bastion_private_ip" {
  description = "Private IP of the bastion."
  value       = module.bastion.private_ip
}

#############################
# Compute
#############################

output "linux_instance_ids" {
  description = "Map of logical name => Linux instance ID."
  value       = module.compute_linux.instance_ids
}

output "linux_private_ips" {
  description = "Map of logical name => Linux private IP."
  value       = module.compute_linux.private_ips
}

output "linux_public_ips" {
  description = "Map of logical name => Linux public IP (empty: these hosts are private)."
  value       = module.compute_linux.public_ips
}

output "windows_instance_ids" {
  description = "Map of logical name => Windows instance ID."
  value       = module.compute_windows.instance_ids
}

output "windows_private_ips" {
  description = "Map of logical name => Windows private IP."
  value       = module.compute_windows.private_ips
}

output "windows_public_ips" {
  description = "Map of logical name => Windows public IP (empty: these hosts are private)."
  value       = module.compute_windows.public_ips
}

# Consolidated view of every host's private and public IP.
output "all_host_private_ips" {
  description = "Map of host => private IP for every instance (bastion, Linux, Windows)."
  value = merge(
    { bastion = module.bastion.private_ip },
    { for k, v in module.compute_linux.private_ips : "linux-${k}" => v },
    { for k, v in module.compute_windows.private_ips : "win-${k}" => v },
  )
}

output "all_host_public_ips" {
  description = "Map of host => public IP. Only the bastion has one; private workloads are empty."
  value = merge(
    { bastion = module.bastion.public_ip },
    { for k, v in module.compute_linux.public_ips : "linux-${k}" => v },
    { for k, v in module.compute_windows.public_ips : "win-${k}" => v },
  )
}

#############################
# Key pair
#############################

output "key_pair_name" {
  description = "Name of the generated EC2 key pair."
  value       = module.keypair.key_name
}

output "private_key_path" {
  description = "Local path to the generated private key .pem (sensitive)."
  value       = module.keypair.private_key_path
  sensitive   = true
}

#############################
# Deployment / IAM
#############################

output "instance_profile_arn" {
  description = "ARN of the SSM instance profile attached to all instances (Session Manager access)."
  value       = module.deployment.instance_profile_arn
}

#############################
# Ansible control node
#############################

output "ansible_control_private_ip" {
  description = "Private IP of the Ansible control node (null when disabled)."
  value       = one(module.ansible_control[*].private_ip)
}

output "ansible_control_instance_id" {
  description = "Instance ID of the Ansible control node (null when disabled)."
  value       = one(module.ansible_control[*].instance_id)
}

output "ansible_control_security_group_id" {
  description = "Control-node SG ID (source of the SSH/WinRM push rules on managed hosts)."
  value       = one(module.ansible_control[*].security_group_id)
}

output "ansible_control_fqdn" {
  description = "Private DNS name of the control node (when DNS + control node are enabled)."
  value       = try(module.dns.record_fqdns["ansible-control"], null)
}

output "ansible_secret_arn" {
  description = "ARN of the consolidated Ansible credentials secret (null when disabled)."
  value       = one(module.secrets[*].secret_arn)
}

output "ansible_secret_name" {
  description = "Name of the consolidated Ansible credentials secret (null when disabled)."
  value       = one(module.secrets[*].secret_name)
}

#############################
# Misc
#############################

output "stack_suffix" {
  description = "The random alphanumeric suffix appended to every resource name."
  value       = random_string.suffix.result
}

output "connection_details_file" {
  description = "Path to the generated connection-details.txt (instance names, IDs, subnets, IPs, SSH/RDP)."
  value       = local_file.connection_details.filename
}
