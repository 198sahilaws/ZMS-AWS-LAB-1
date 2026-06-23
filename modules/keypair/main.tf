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

# Write the private key locally with 0600 permissions for immediate use.
resource "local_sensitive_file" "private_key" {
  content         = tls_private_key.this.private_key_pem
  filename        = local.pem_file_path
  file_permission = "0600"
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
