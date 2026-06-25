locals {
  sfx = var.suffix == "" ? "" : "-${var.suffix}"
}

# One consolidated secret per deployment holding all Ansible credentials as a JSON
# document: { ssh_private_key, winrm_username, winrm_password, provision_key }. The
# SSH value is mirrored from the generated key; the WinRM values come from the Windows
# admin inputs; provision_key is an arbitrary provisioning nonce — so the bundle is
# self-contained (no separate out-of-band step needed).
resource "aws_secretsmanager_secret" "ansible" {
  name        = "${var.name_prefix}/ansible-credentials${local.sfx}"
  description = "Consolidated Ansible credentials (SSH private key + WinRM account)"

  recovery_window_in_days = var.recovery_window_in_days

  tags = merge(var.tags, { Name = "${var.name_prefix}-ansible-credentials${local.sfx}" })
}

resource "aws_secretsmanager_secret_version" "ansible" {
  count = var.set_secret ? 1 : 0

  secret_id = aws_secretsmanager_secret.ansible.id
  secret_string = jsonencode({
    ssh_private_key = var.ssh_private_key
    winrm_username  = var.winrm_username
    winrm_password  = var.winrm_password
    provision_key   = var.provision_key
  })
}
