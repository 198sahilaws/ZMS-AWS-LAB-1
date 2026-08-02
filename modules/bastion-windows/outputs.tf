output "instance_id" {
  description = "Windows bastion EC2 instance ID."
  value       = aws_instance.bastion.id
}

output "security_group_id" {
  description = "Windows bastion security group ID."
  value       = aws_security_group.bastion.id
}

output "public_ip" {
  description = "Public IP of the Windows bastion (Elastic IP when associate_eip is true)."
  value       = var.associate_eip ? aws_eip.bastion[0].public_ip : aws_instance.bastion.public_ip
}

output "public_dns" {
  description = "Public DNS name of the Windows bastion."
  value       = aws_instance.bastion.public_dns
}

output "private_ip" {
  description = "Private IP of the Windows bastion."
  value       = aws_instance.bastion.private_ip
}
