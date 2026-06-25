output "secret_arn" {
  description = "ARN of the consolidated Ansible credentials secret."
  value       = aws_secretsmanager_secret.ansible.arn
}

output "secret_name" {
  description = "Name of the consolidated Ansible credentials secret."
  value       = aws_secretsmanager_secret.ansible.name
}
