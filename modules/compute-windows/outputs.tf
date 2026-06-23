output "instance_ids" {
  description = "Map of logical name => Windows instance ID."
  value       = { for k, i in aws_instance.windows : k => i.id }
}

output "private_ips" {
  description = "Map of logical name => private IP."
  value       = { for k, i in aws_instance.windows : k => i.private_ip }
}

output "public_ips" {
  description = "Map of logical name => public IP (empty for these private hosts; present only if launched with a public IP)."
  value       = { for k, i in aws_instance.windows : k => i.public_ip }
}

output "security_group_id" {
  description = "Security group ID shared by the Windows workloads."
  value       = aws_security_group.windows.id
}

output "dns_records" {
  description = "Map of hostname => private IP for DNS registration (hostnames prefixed with win-)."
  value       = { for k, i in aws_instance.windows : "win-${k}" => i.private_ip }
}
