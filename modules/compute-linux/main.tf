locals {
  sfx      = var.suffix == "" ? "" : "-${var.suffix}"
  az_count = length(var.subnet_ids)

  # One pool per Linux OS, each with its own count and AMI.
  pools = {
    amazon = { count = var.amazon_linux_server_count, ami = var.amazon_linux_ami_ssm_parameter }
    ubuntu = { count = var.ubuntu_server_count, ami = var.ubuntu_ami_ssm_parameter }
  }

  # Expand each pool into N instances, round-robining the pool index across the
  # AZ subnets: server i of a pool lands in subnet_ids[i % az_count].
  pool_maps = [
    for pool, cfg in local.pools : {
      for i in range(cfg.count) : "${pool}-${i + 1}" => {
        ami_param    = cfg.ami
        role         = pool
        subnet_index = i % local.az_count
      }
    }
  ]
  instances = merge(local.pool_maps...)

  # Distinct AMI parameters actually referenced (deduplicated).
  ami_params = toset([for inst in values(local.instances) : inst.ami_param])
}

# Resolve each referenced AMI region-agnostically from its SSM parameter.
data "aws_ssm_parameter" "ami" {
  for_each = local.ami_params
  name     = each.value
}

# Linux workloads accept SSH from the bastion SG and (when set) the control SG.
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
  for_each = local.instances

  ami                    = data.aws_ssm_parameter.ami[each.value.ami_param].value
  instance_type          = var.instance_type
  subnet_id              = var.subnet_ids[each.value.subnet_index]
  key_name               = var.key_name
  vpc_security_group_ids = [aws_security_group.linux.id]
  iam_instance_profile   = var.iam_instance_profile

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
    Role = each.value.role
  })
}
