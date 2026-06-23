locals {
  sfx           = var.suffix == "" ? "" : "-${var.suffix}"
  instance_keys = keys(var.instances)
}

# Resolve each instance's AMI region-agnostically from its SSM parameter.
data "aws_ssm_parameter" "ami" {
  for_each = var.instances
  name     = each.value.ami_ssm_parameter
}

# Linux workloads accept SSH only from the bastion SG. No public ingress.
resource "aws_security_group" "linux" {
  name        = "${var.name_prefix}-linux-sg${local.sfx}"
  description = "Linux workloads: SSH from bastion only, egress within VPC"
  vpc_id      = var.vpc_id

  ingress {
    description     = "SSH from the bastion security group"
    from_port       = 22
    to_port         = 22
    protocol        = "tcp"
    security_groups = [var.bastion_security_group_id]
  }

  # Ansible push path: SSH from the control node SG (only when provided).
  dynamic "ingress" {
    for_each = var.control_security_group_id != null ? [1] : []
    content {
      description     = "SSH from the Ansible control node"
      from_port       = 22
      to_port         = 22
      protocol        = "tcp"
      security_groups = [var.control_security_group_id]
    }
  }

  egress {
    description = "Egress to the VPC (reach VPC endpoints / other hosts)"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = [var.vpc_cidr]
  }

  # Allow HTTPS egress to AWS service prefix lists is covered by the VPC-CIDR
  # egress because interface endpoints live inside the VPC. NAT egress for
  # OS package mirrors:
  egress {
    description = "HTTPS egress for package mirrors via NAT"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(var.tags, { Name = "${var.name_prefix}-linux-sg${local.sfx}" })
}

resource "aws_instance" "linux" {
  for_each = var.instances

  ami           = data.aws_ssm_parameter.ami[each.key].value
  instance_type = coalesce(each.value.instance_type, var.default_instance_type)
  # Spread instances across the available private subnets by index.
  subnet_id              = element(var.subnet_ids, index(local.instance_keys, each.key))
  key_name               = var.key_name
  vpc_security_group_ids = [aws_security_group.linux.id]
  iam_instance_profile   = var.iam_instance_profile

  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 1
  }

  root_block_device {
    volume_size = coalesce(each.value.root_volume_size, var.default_root_volume_size)
    volume_type = "gp3"
    encrypted   = true
    kms_key_id  = var.kms_key_id
    tags        = merge(var.tags, { Name = "${var.name_prefix}-linux-${each.key}-root${local.sfx}" })
  }

  user_data = <<-EOT
    #cloud-config
    runcmd:
      - systemctl enable --now amazon-ssm-agent snap.amazon-ssm-agent.amazon-ssm-agent.service || true
  EOT

  tags = merge(var.tags, {
    Name = "${var.name_prefix}-linux-${each.key}${local.sfx}"
    OS   = "linux"
    Role = coalesce(each.value.role, "linux-workload")
  })
}
