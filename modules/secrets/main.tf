locals {
  sfx = var.suffix == "" ? "" : "-${var.suffix}"
}

# One consolidated secret per deployment holding ALL Ansible credentials as a JSON
# document, so every playbook reads a single secret:
#   { ssh_private_key, winrm_username, winrm_password, provision_key,
#     dsrm_password, domain_join_username, domain_join_password, mysql_root_password }
# SSH is mirrored from the generated key and WinRM from the Windows admin inputs;
# the rest are driven by terraform.tfvars (empty by default). provision_key doubles
# as the ZMS Enforcer nonce.
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
    ssh_private_key      = var.ssh_private_key
    winrm_username       = var.winrm_username
    winrm_password       = var.winrm_password
    provision_key        = var.provision_key
    dsrm_password        = var.dsrm_password
    domain_join_username = var.domain_join_username
    domain_join_password = var.domain_join_password
    mysql_root_password  = var.mysql_root_password
  })
}
