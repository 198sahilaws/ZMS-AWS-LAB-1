output "instance_profile_name" {
  description = "Name of the IAM instance profile to attach to all EC2 instances."
  value       = aws_iam_instance_profile.ssm.name
}

output "instance_profile_arn" {
  description = "ARN of the IAM instance profile."
  value       = aws_iam_instance_profile.ssm.arn
}

output "instance_role_arn" {
  description = "ARN of the IAM role used by instances."
  value       = aws_iam_role.ssm.arn
}
