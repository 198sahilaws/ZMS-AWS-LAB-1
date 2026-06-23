locals {
  sfx = var.suffix == "" ? "" : "-${var.suffix}"
}

# Containers only — values are mirrored from the generated key (SSH) or set out
# of band (WinRM), so plaintext never has to be authored in code.

resource "aws_secretsmanager_secret" "ssh" {
  name        = "${var.name_prefix}/ansible-ssh-private-key${local.sfx}"
  description = "Private key the Ansible control node uses for Linux SSH"

  recovery_window_in_days = var.recovery_window_in_days

  tags = merge(var.tags, { Name = "${var.name_prefix}-ansible-ssh-key${local.sfx}" })
}

resource "aws_secretsmanager_secret_version" "ssh" {
  # Gate only on the (plan-known) flag. The key material comes from the keypair
  # module and is unknown until apply, so it must not appear in `count`.
  count = var.set_ssh_secret ? 1 : 0

  secret_id     = aws_secretsmanager_secret.ssh.id
  secret_string = var.ssh_private_key
}

resource "aws_secretsmanager_secret" "winrm" {
  name        = "${var.name_prefix}/winrm-credential${local.sfx}"
  description = "Windows account Ansible uses over WinRM"

  recovery_window_in_days = var.recovery_window_in_days

  tags = merge(var.tags, { Name = "${var.name_prefix}-winrm-credential${local.sfx}" })
}

resource "aws_secretsmanager_secret_version" "winrm" {
  count = var.set_winrm_secret ? 1 : 0

  secret_id = aws_secretsmanager_secret.winrm.id
  secret_string = jsonencode({
    username = var.winrm_username
    password = var.winrm_password
  })
}
