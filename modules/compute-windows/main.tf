locals {
  sfx      = var.suffix == "" ? "" : "-${var.suffix}"
  az_count = length(var.subnet_ids)

  # One instance per role entry, round-robining across AZ subnets: server i lands
  # in subnet_ids[i % az_count]. Role is the (lowercase) value the operator
  # assigned -> Role tag -> role_<value> inventory group. A "dc" role additionally
  # gets Domain_Controller=Enabled.
  instances = {
    for idx, role in var.windows_server_roles : tostring(idx + 1) => {
      subnet_index = idx % local.az_count
      role         = role
      is_dc        = role == "dc"
    }
  }

  # First-boot PowerShell: ensure the SSM agent is running, set the local admin
  # account, and stand up a WinRM HTTPS listener on 5986 so the host is
  # immediately manageable by Ansible (ntlm transport over TLS).
  user_data = <<-POWERSHELL
    <powershell>
    Start-Transcript -Path "C:\Windows\Temp\winrm-bootstrap.log" -Append
    $ErrorActionPreference = "Stop"

    # --- SSM agent (Session Manager access) ---
    Set-Service -Name AmazonSSMAgent -StartupType Automatic
    Start-Service AmazonSSMAgent

    # --- Local admin account used by Ansible over WinRM ---
    $User = "${var.windows_admin_username}"
    $Pass = ConvertTo-SecureString "${var.windows_admin_password}" -AsPlainText -Force
    if (Get-LocalUser -Name $User -ErrorAction SilentlyContinue) {
      Set-LocalUser -Name $User -Password $Pass
    } else {
      New-LocalUser -Name $User -Password $Pass -PasswordNeverExpires -AccountNeverExpires
      Add-LocalGroupMember -Group "Administrators" -Member $User
    }

    # --- Enable WinRM over HTTPS (5986) for Ansible ---
    # Base remoting first. -SkipNetworkProfileCheck is required because EC2's NIC
    # starts on the "Public" profile, which otherwise blocks WinRM setup.
    Enable-PSRemoting -Force -SkipNetworkProfileCheck
    Set-Service -Name WinRM -StartupType Automatic

    # Self-signed server-authentication certificate for the HTTPS listener.
    $cert = New-SelfSignedCertificate -DnsName $env:COMPUTERNAME -CertStoreLocation Cert:\LocalMachine\My

    # (Re)create the HTTPS listener on 5986 bound to that certificate.
    Get-ChildItem WSMan:\localhost\Listener | Where-Object { $_.Keys -contains "Transport=HTTPS" } | Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
    New-Item -Path WSMan:\localhost\Listener -Transport HTTPS -Address * -CertificateThumbPrint $cert.Thumbprint -Force

    # Require encryption; keep Negotiate/NTLM enabled (Ansible's ntlm transport).
    Set-Item -Path WSMan:\localhost\Service\Auth\Negotiate -Value $true
    Set-Item -Path WSMan:\localhost\Service\AllowUnencrypted -Value $false

    # Raise the per-shell memory ceiling so Ansible PowerShell modules don't OOM.
    try { Set-Item -Path WSMan:\localhost\Shell\MaxMemoryPerShellMB -Value 2048 } catch {}

    # Allow 5986 inbound at the OS firewall (the security group limits the source).
    New-NetFirewallRule -DisplayName "WinRM HTTPS 5986" -Direction Inbound -LocalPort 5986 -Protocol TCP -Action Allow -ErrorAction SilentlyContinue

    Restart-Service WinRM
    Stop-Transcript
    </powershell>
    <persist>false</persist>
  POWERSHELL
}

# Resolve the Windows AMI region-agnostically from its SSM parameter.
data "aws_ssm_parameter" "ami" {
  name = var.windows_ami_ssm_parameter
}

# Windows workloads accept RDP from the bastion/VPC and WinRM from the control SG.
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
  for_each = local.instances

  ami                    = data.aws_ssm_parameter.ami.value
  instance_type          = var.instance_type
  subnet_id              = var.subnet_ids[each.value.subnet_index]
  vpc_security_group_ids = [aws_security_group.windows.id]
  iam_instance_profile   = var.iam_instance_profile
  user_data              = local.user_data

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
    tags        = merge(var.tags, { Name = "${var.name_prefix}-windows-${each.key}-root${local.sfx}" })
  }

  tags = merge(
    var.tags,
    {
      Name = "${var.name_prefix}-windows-${each.key}${local.sfx}"
      OS   = "windows"
      Role = each.value.role
    },
    # A "dc"-role Windows server is also flagged as the domain controller.
    each.value.is_dc ? { Domain_Controller = "Enabled" } : {},
  )
}
