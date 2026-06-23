output "ssh_secret_arn" {
  description = "ARN of the Ansible SSH private-key secret."
  value       = aws_secretsmanager_secret.ssh.arn
}

output "ssh_secret_name" {
  description = "Name of the Ansible SSH private-key secret."
  value       = aws_secretsmanager_secret.ssh.name
}

output "winrm_secret_arn" {
  description = "ARN of the WinRM credential secret."
  value       = aws_secretsmanager_secret.winrm.arn
}

output "winrm_secret_name" {
  description = "Name of the WinRM credential secret."
  value       = aws_secretsmanager_secret.winrm.name
}
