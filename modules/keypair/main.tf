locals {
  sfx           = var.suffix == "" ? "" : "-${var.suffix}"
  key_name      = var.key_name != "" ? var.key_name : "${var.name_prefix}-key${local.sfx}"
  key_dir       = var.private_key_path != "" ? var.private_key_path : path.root
  pem_file_path = "${local.key_dir}/${local.key_name}.pem"
}

# Generate a fresh SSH key pair. This single key pair is used to reach the
# bastion and all Linux hosts.
resource "tls_private_key" "this" {
  algorithm = var.algorithm
  rsa_bits  = var.algorithm == "RSA" ? var.rsa_bits : null
}

resource "aws_key_pair" "this" {
  key_name   = local.key_name
  public_key = tls_private_key.this.public_key_openssh

  tags = merge(var.tags, { Name = local.key_name })
}

# Write the private key locally for immediate use. On Linux/macOS file_permission
# sets the mode directly (0600). On Windows this Unix mode is IGNORED — the file
# inherits the directory ACL (which includes "Authenticated Users"), so OpenSSH
# refuses the key ("permissions are too open"). terraform_data.key_permissions
# below repairs the Windows ACL so the file works everywhere.
resource "local_sensitive_file" "private_key" {
  content         = tls_private_key.this.private_key_pem
  filename        = local.pem_file_path
  file_permission = "0600"
}

locals {
  # Detect Windows without an external data source: pathexpand("~") returns a
  # drive-letter path ("C:\Users\...") on Windows but a "/..." path on Unix.
  is_windows   = substr(pathexpand("~"), 0, 1) != "/"
  key_abs_path = abspath(local_sensitive_file.private_key.filename)
  key_win_path = replace(local.key_abs_path, "/", "\\")

  # Windows: strip inherited ACEs and grant read to ONLY the current user.
  # Unix: re-assert 0600 (already set above; harmless belt-and-suspenders).
  fix_perms_cmd = local.is_windows ? "icacls \"${local.key_win_path}\" /inheritance:r /grant:r \"$($env:USERNAME):(R)\"" : "chmod 600 '${local.key_abs_path}'"
}

# Repair the private key's on-disk permissions so SSH accepts it on every OS.
# Re-runs whenever the key file is (re)generated.
resource "terraform_data" "key_permissions" {
  triggers_replace = [local_sensitive_file.private_key.id]

  provisioner "local-exec" {
    interpreter = local.is_windows ? ["PowerShell", "-NoProfile", "-Command"] : ["/bin/sh", "-c"]
    command     = local.fix_perms_cmd
  }
}

# Optionally mirror the key into SSM Parameter Store (SecureString).
resource "aws_ssm_parameter" "private_key" {
  count = var.store_in_ssm ? 1 : 0

  name        = "/${var.name_prefix}/ssh/private-key${local.sfx}"
  description = "Private SSH key for ${local.key_name}"
  type        = "SecureString"
  value       = tls_private_key.this.private_key_pem

  tags = merge(var.tags, { Name = "${local.key_name}-ssm" })
}
