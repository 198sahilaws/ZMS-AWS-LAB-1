locals {
  sfx      = var.suffix == "" ? "" : "-${var.suffix}"
  az_count = length(var.subnet_ids)

  # One pool per Linux OS, each with an explicit list of roles and an AMI.
  pools = {
    amazon = { roles = var.amazon_linux_server_roles, ami = var.amazon_linux_ami_ssm_parameter }
    ubuntu = { roles = var.ubuntu_server_roles, ami = var.ubuntu_ami_ssm_parameter }
  }

  # Expand each pool into one instance per role entry, round-robining the list
  # index across the AZ subnets: server i of a pool lands in subnet_ids[i % az_count].
  # Role is the (lowercase) value the operator assigned -> Role tag -> role_<value>
  # inventory group. Distro carries the OS flavor (drives the SSH login user).
  pool_maps = [
    for pool, cfg in local.pools : {
      for idx, role in cfg.roles : "${pool}-${idx + 1}" => {
        ami_param    = cfg.ami
        distro       = pool
        role         = role
        username     = pool == "ubuntu" ? "ubuntu" : "ec2-user"
        subnet_index = idx % local.az_count
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
  description = "Linux workloads: all inbound from the VPC, all outbound"
  vpc_id      = var.vpc_id

  # Allow ALL inbound from within the VPC (every subnet range). This covers the
  # control node's SSH push, bastion access, and host-to-host traffic without
  # per-port rules. Non-VPC inbound is dropped by the default deny. The bastions
  # are NOT in this group — they keep their own internet-facing, admin-CIDR-locked
  # SGs, so they are excluded from this permissive rule.
  ingress {
    description = "All inbound from within the VPC"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = [var.vpc_cidr]
  }

  egress {
    description = "All outbound to anywhere"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
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
    Name   = "${var.name_prefix}-linux-${each.key}${local.sfx}"
    OS     = "linux"
    Distro = each.value.distro
    Role   = each.value.role
  })
}
