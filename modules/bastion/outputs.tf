output "instance_id" {
  description = "Bastion EC2 instance ID."
  value       = aws_instance.bastion.id
}

output "security_group_id" {
  description = "Bastion security group ID (referenced by workload SGs to allow SSH from the bastion)."
  value       = aws_security_group.bastion.id
}

output "public_ip" {
  description = "Public IP of the bastion (Elastic IP when associate_eip is true)."
  value       = var.associate_eip ? aws_eip.bastion[0].public_ip : aws_instance.bastion.public_ip
}

output "public_dns" {
  description = "Public DNS name of the bastion."
  value       = aws_instance.bastion.public_dns
}

output "private_ip" {
  description = "Private IP of the bastion."
  value       = aws_instance.bastion.private_ip
}
