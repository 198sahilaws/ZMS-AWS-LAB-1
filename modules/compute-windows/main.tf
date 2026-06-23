locals {
  sfx           = var.suffix == "" ? "" : "-${var.suffix}"
  instance_keys = keys(var.instances)

  # First-boot PowerShell: ensure the SSM agent is running, set the local admin
  # account, and (for Ansible push) stand up a WinRM HTTPS listener on 5986.
  user_data = <<-POWERSHELL
    <powershell>
    Set-Service -Name AmazonSSMAgent -StartupType Automatic
    Start-Service AmazonSSMAgent
    $User = "${var.windows_admin_username}"
    $Pass = ConvertTo-SecureString "${var.windows_admin_password}" -AsPlainText -Force
    if (Get-LocalUser -Name $User -ErrorAction SilentlyContinue) {
      Set-LocalUser -Name $User -Password $Pass
    } else {
      New-LocalUser -Name $User -Password $Pass -PasswordNeverExpires -AccountNeverExpires
      Add-LocalGroupMember -Group "Administrators" -Member $User
    }
    # WinRM over HTTPS (5986) for Ansible. Self-signed cert; encrypted transport.
    winrm quickconfig -quiet
    $cert = New-SelfSignedCertificate -DnsName $env:COMPUTERNAME -CertStoreLocation Cert:\LocalMachine\My
    New-Item -Path WSMan:\localhost\Listener -Transport HTTPS -Address * -CertificateThumbPrint $cert.Thumbprint -Force
    Set-Item -Path WSMan:\localhost\Service\Auth\Basic -Value $true
    Set-Item -Path WSMan:\localhost\Service\AllowUnencrypted -Value $false
    Enable-PSRemoting -Force -SkipNetworkProfileCheck
    New-NetFirewallRule -DisplayName "WinRM HTTPS 5986" -Direction Inbound -LocalPort 5986 -Protocol TCP -Action Allow -ErrorAction SilentlyContinue
    </powershell>
    <persist>false</persist>
  POWERSHELL
}

data "aws_ssm_parameter" "ami" {
  for_each = var.instances
  name     = each.value.ami_ssm_parameter
}

# Windows workloads accept RDP only from the bastion SG and the VPC range.
resource "aws_security_group" "windows" {
  name        = "${var.name_prefix}-windows-sg${local.sfx}"
  description = "Windows workloads: RDP from bastion/VPC only, never the internet"
  vpc_id      = var.vpc_id

  ingress {
    description     = "RDP from the bastion security group"
    from_port       = 3389
    to_port         = 3389
    protocol        = "tcp"
    security_groups = [var.bastion_security_group_id]
  }

  ingress {
    description = "RDP from within the VPC"
    from_port   = 3389
    to_port     = 3389
    protocol    = "tcp"
    cidr_blocks = [var.vpc_cidr]
  }

  # Ansible push path: WinRM HTTPS from the control node SG (only when provided).
  dynamic "ingress" {
    for_each = var.control_security_group_id != null ? [1] : []
    content {
      description     = "WinRM HTTPS from the Ansible control node"
      from_port       = 5986
      to_port         = 5986
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
    description = "HTTPS egress for updates / package mirrors via NAT"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(var.tags, { Name = "${var.name_prefix}-windows-sg${local.sfx}" })
}

resource "aws_instance" "windows" {
  for_each = var.instances

  ami                    = data.aws_ssm_parameter.ami[each.key].value
  instance_type          = coalesce(each.value.instance_type, var.default_instance_type)
  subnet_id              = element(var.subnet_ids, index(local.instance_keys, each.key))
  vpc_security_group_ids = [aws_security_group.windows.id]
  iam_instance_profile   = var.iam_instance_profile
  user_data              = local.user_data

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
    tags        = merge(var.tags, { Name = "${var.name_prefix}-windows-${each.key}-root${local.sfx}" })
  }

  tags = merge(var.tags, {
    Name = "${var.name_prefix}-windows-${each.key}${local.sfx}"
    OS   = "windows"
    Role = coalesce(each.value.role, "windows-workload")
  })
}
