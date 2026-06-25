locals {
  sfx = var.suffix == "" ? "" : "-${var.suffix}"
  # Only grant secret reads for ARNs that were actually provided.
  readable_secret_arns = compact([var.ssh_secret_arn, var.winrm_secret_arn])
}

data "aws_partition" "current" {}

# Resolve the control-node AMI region-agnostically from an SSM public parameter.
data "aws_ssm_parameter" "ami" {
  name = var.ami_ssm_parameter
}

# AZ of the chosen subnet, so the repo volume is created alongside the instance.
data "aws_subnet" "selected" {
  id = var.subnet_id
}

#############################
# Security group (private; admin SSH from the bastion only)
#############################

resource "aws_security_group" "control" {
  name        = "${var.name_prefix}-ansible-control-sg${local.sfx}"
  description = "Ansible control node: admin SSH from bastion; egress to managed hosts and repos"
  vpc_id      = var.vpc_id

  ingress {
    description     = "Admin SSH from the bastion security group"
    from_port       = 22
    to_port         = 22
    protocol        = "tcp"
    security_groups = [var.bastion_security_group_id]
  }

  egress {
    description = "All egress (push to managed hosts, pull repos via NAT, reach SSM endpoints)"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(var.tags, { Name = "${var.name_prefix}-ansible-control-sg${local.sfx}" })
}

#############################
# IAM — dynamic inventory (EC2 read) + scoped secrets read + SSM core
#############################

data "aws_iam_policy_document" "assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "control" {
  name               = "${var.name_prefix}-ansible-control-role${local.sfx}"
  assume_role_policy = data.aws_iam_policy_document.assume.json

  tags = merge(var.tags, { Name = "${var.name_prefix}-ansible-control-role${local.sfx}" })
}

# Read-only EC2 for the amazon.aws.aws_ec2 dynamic inventory plugin.
data "aws_iam_policy_document" "inventory" {
  statement {
    sid = "Ec2InventoryRead"
    actions = [
      "ec2:DescribeInstances",
      "ec2:DescribeTags",
      "ec2:DescribeRegions",
      "ec2:DescribeInstanceAttribute",
    ]
    resources = ["*"]
  }
}

resource "aws_iam_role_policy" "inventory" {
  name   = "${var.name_prefix}-ec2-inventory-read${local.sfx}"
  role   = aws_iam_role.control.id
  policy = data.aws_iam_policy_document.inventory.json
}

# Scoped read of exactly the secrets the control node needs.
# Gated on the (plan-known) `attach_secrets_policy` flag — the secret ARNs are
# resolved from the secrets module and are unknown until apply, so they cannot
# drive `count`.
data "aws_iam_policy_document" "secrets" {
  count = var.attach_secrets_policy ? 1 : 0

  statement {
    sid       = "SecretsRead"
    actions   = ["secretsmanager:GetSecretValue"]
    resources = local.readable_secret_arns
  }
}

resource "aws_iam_role_policy" "secrets" {
  count  = var.attach_secrets_policy ? 1 : 0
  name   = "${var.name_prefix}-secrets-read${local.sfx}"
  role   = aws_iam_role.control.id
  policy = data.aws_iam_policy_document.secrets[0].json
}

# Session Manager access (the control node is private; reach it without SSH).
resource "aws_iam_role_policy_attachment" "ssm_core" {
  role       = aws_iam_role.control.name
  policy_arn = "arn:${data.aws_partition.current.partition}:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_instance_profile" "control" {
  name = "${var.name_prefix}-ansible-control-profile${local.sfx}"
  role = aws_iam_role.control.name

  tags = merge(var.tags, { Name = "${var.name_prefix}-ansible-control-profile${local.sfx}" })
}

#############################
# Control node instance + persistent repo volume
#############################

resource "aws_instance" "control" {
  ami                         = data.aws_ssm_parameter.ami.value
  instance_type               = var.instance_type
  subnet_id                   = var.subnet_id
  key_name                    = var.key_name
  iam_instance_profile        = aws_iam_instance_profile.control.name
  vpc_security_group_ids      = [aws_security_group.control.id]
  associate_public_ip_address = false

  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 1
  }

  root_block_device {
    volume_type = "gp3"
    volume_size = var.root_volume_size
    encrypted   = true
    kms_key_id  = var.kms_key_id
    tags        = merge(var.tags, { Name = "${var.name_prefix}-ansible-control-root${local.sfx}" })
  }

  user_data = templatefile("${path.module}/cloud-init.yaml", {
    control_repo_url    = var.control_repo_url
    control_repo_branch = var.control_repo_branch
    reconverge_minutes  = var.reconverge_minutes
    aws_region          = var.aws_region
    ssh_secret_name     = var.ssh_secret_name
    ssh_secret_arn      = var.ssh_secret_arn
    winrm_secret_name   = var.winrm_secret_name
    winrm_secret_arn    = var.winrm_secret_arn
  })

  tags = merge(var.tags, {
    Name = "${var.name_prefix}-ansible-control${local.sfx}"
    Role = "ansible-control"
  })
}

resource "aws_ebs_volume" "repos" {
  availability_zone = data.aws_subnet.selected.availability_zone
  size              = var.repo_volume_size
  type              = "gp3"
  encrypted         = true
  kms_key_id        = var.kms_key_id

  tags = merge(var.tags, { Name = "${var.name_prefix}-ansible-repos${local.sfx}" })
}

resource "aws_volume_attachment" "repos" {
  device_name = "/dev/sdf" # Nitro surfaces this as /dev/nvme1n1
  volume_id   = aws_ebs_volume.repos.id
  instance_id = aws_instance.control.id
}
