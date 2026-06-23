output "instance_id" {
  description = "Control node EC2 instance ID."
  value       = aws_instance.control.id
}

output "private_ip" {
  description = "Private IP of the control node."
  value       = aws_instance.control.private_ip
}

output "security_group_id" {
  description = "Control node SG ID (referenced by managed-host SGs to allow Ansible push)."
  value       = aws_security_group.control.id
}

output "iam_role_arn" {
  description = "ARN of the control node IAM role."
  value       = aws_iam_role.control.arn
}

output "instance_profile_name" {
  description = "Name of the control node instance profile."
  value       = aws_iam_instance_profile.control.name
}

output "repo_volume_id" {
  description = "ID of the persistent repo EBS volume."
  value       = aws_ebs_volume.repos.id
}
