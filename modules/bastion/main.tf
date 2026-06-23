locals {
  sfx = var.suffix == "" ? "" : "-${var.suffix}"
}

# Resolve the bastion AMI region-agnostically from an SSM public parameter.
data "aws_ssm_parameter" "ami" {
  name = var.ami_ssm_parameter
}

# The only internet-facing SSH entry point. Ingress 22 is locked to admin CIDRs.
resource "aws_security_group" "bastion" {
  name        = "${var.name_prefix}-bastion-sg${local.sfx}"
  description = "Bastion host: SSH in from admin CIDRs only, egress into the VPC"
  vpc_id      = var.vpc_id

  ingress {
    description = "SSH from approved admin CIDRs"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = var.bastion_allowed_cidrs
  }

  egress {
    description = "All egress (reach private hosts, SSM endpoints, package mirrors)"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(var.tags, { Name = "${var.name_prefix}-bastion-sg${local.sfx}" })
}

resource "aws_instance" "bastion" {
  ami                         = data.aws_ssm_parameter.ami.value
  instance_type               = var.instance_type
  subnet_id                   = var.subnet_id
  key_name                    = var.key_name
  vpc_security_group_ids      = [aws_security_group.bastion.id]
  iam_instance_profile        = var.iam_instance_profile
  associate_public_ip_address = true

  # Enforce IMDSv2.
  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 1
  }

  root_block_device {
    volume_size = var.root_volume_size
    volume_type = "gp3"
    encrypted   = true
    kms_key_id  = var.kms_key_id
    tags        = merge(var.tags, { Name = "${var.name_prefix}-bastion-root${local.sfx}" })
  }

  user_data = <<-EOT
    #cloud-config
    package_update: true
    runcmd:
      - systemctl enable --now amazon-ssm-agent snap.amazon-ssm-agent.amazon-ssm-agent.service || true
  EOT

  tags = merge(var.tags, {
    Name = "${var.name_prefix}-bastion${local.sfx}"
    Role = "bastion"
  })
}

resource "aws_eip" "bastion" {
  count    = var.associate_eip ? 1 : 0
  instance = aws_instance.bastion.id
  domain   = "vpc"

  tags = merge(var.tags, { Name = "${var.name_prefix}-bastion-eip${local.sfx}" })
}
