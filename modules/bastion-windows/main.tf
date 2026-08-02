locals {
  sfx = var.suffix == "" ? "" : "-${var.suffix}"
}

# Resolve the Windows bastion AMI region-agnostically from an SSM public parameter.
data "aws_ssm_parameter" "ami" {
  name = var.ami_ssm_parameter
}

# Internet-facing RDP entry point for the Windows estate. Ingress 3389 is locked
# to admin CIDRs; optional SSH (22) for RDP-less admin tooling.
resource "aws_security_group" "bastion" {
  name        = "${var.name_prefix}-winbastion-sg${local.sfx}"
  description = "Windows bastion: RDP in from admin CIDRs only, egress into the VPC"
  vpc_id      = var.vpc_id

  ingress {
    description = "RDP from approved admin CIDRs"
    from_port   = 3389
    to_port     = 3389
    protocol    = "tcp"
    cidr_blocks = var.bastion_allowed_cidrs
  }

  egress {
    description = "All egress (reach private hosts, SSM endpoints, Windows Update)"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(var.tags, { Name = "${var.name_prefix}-winbastion-sg${local.sfx}" })
}

resource "aws_instance" "bastion" {
  ami                         = data.aws_ssm_parameter.ami.value
  instance_type               = var.instance_type
  subnet_id                   = var.subnet_id
  vpc_security_group_ids      = [aws_security_group.bastion.id]
  iam_instance_profile        = var.iam_instance_profile
  associate_public_ip_address = true

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
    tags        = merge(var.tags, { Name = "${var.name_prefix}-winbastion-root${local.sfx}" })
  }

  # First-boot: ensure the SSM agent runs, set the local admin account, and make
  # sure RDP is enabled. No WinRM listener — this host is for human RDP only and
  # is deliberately NOT managed by Ansible.
  user_data = <<-POWERSHELL
    <powershell>
    Set-Service -Name AmazonSSMAgent -StartupType Automatic
    Start-Service AmazonSSMAgent
    $User = "${var.admin_username}"
    $Pass = ConvertTo-SecureString "${var.admin_password}" -AsPlainText -Force
    if (Get-LocalUser -Name $User -ErrorAction SilentlyContinue) {
      Set-LocalUser -Name $User -Password $Pass
    } else {
      New-LocalUser -Name $User -Password $Pass -PasswordNeverExpires -AccountNeverExpires
      Add-LocalGroupMember -Group "Administrators" -Member $User
    }
    Set-ItemProperty -Path 'HKLM:\System\CurrentControlSet\Control\Terminal Server' -Name 'fDenyTSConnections' -Value 0
    Enable-NetFirewallRule -DisplayGroup "Remote Desktop"
    </powershell>
    <persist>false</persist>
  POWERSHELL

  # Role=bastion and OS=bastion (NOT os=windows) so the Ansible aws_ec2 inventory
  # never places this host in os_windows / role_* and never targets it.
  tags = merge(var.tags, {
    Name = "${var.name_prefix}-winbastion${local.sfx}"
    Role = "bastion"
    OS   = "bastion"
  })
}

resource "aws_eip" "bastion" {
  count    = var.associate_eip ? 1 : 0
  instance = aws_instance.bastion.id
  domain   = "vpc"

  tags = merge(var.tags, { Name = "${var.name_prefix}-winbastion-eip${local.sfx}" })
}
