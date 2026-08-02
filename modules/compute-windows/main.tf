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
      # Both a writable DC and a read-only DC are domain controllers.
      is_dc = role == "dc" || role == "rodc"
    }
  }

  # First-boot PowerShell: ensure the SSM agent is running, set the local admin
  # account, and stand up a WinRM HTTPS listener on 5986 so the host is
  # immediately manageable by Ansible (ntlm transport over TLS).
  # IMPORTANT: this script must NEVER abort before the local admin account exists.
  # EC2Launch v2 on Windows Server 2016+ stands up its OWN WinRM HTTPS listener on
  # 5986, so if this script dies early the port still answers while the account is
  # missing — Ansible then fails with the misleading
  #   "ntlm: the specified credentials were rejected by the server"
  # on every fresh deploy. The previous version set $ErrorActionPreference="Stop"
  # globally, so a single hiccup (e.g. the SSM service already in a transitional
  # state) silently skipped account creation. Each stage is now wrapped in
  # try/catch, the account is created FIRST, and errors are logged, not fatal.
  user_data = <<-POWERSHELL
    <powershell>
    Start-Transcript -Path "C:\Windows\Temp\winrm-bootstrap.log" -Append
    $ErrorActionPreference = "Continue"

    # --- 1. Local admin account used by Ansible over WinRM (FIRST: most critical) --
    # Single-quoted PowerShell literals so passwords containing $ ` or " are safe.
    $User = '${var.windows_admin_username}'
    $Pass = ConvertTo-SecureString '${var.windows_admin_password}' -AsPlainText -Force
    try {
      if (Get-LocalUser -Name $User -ErrorAction SilentlyContinue) {
        Write-Output "Account $User exists - resetting password"
        Set-LocalUser -Name $User -Password $Pass -PasswordNeverExpires $true
      } else {
        Write-Output "Creating account $User"
        New-LocalUser -Name $User -Password $Pass -PasswordNeverExpires -AccountNeverExpires
      }
      Enable-LocalUser -Name $User
      # Always (re)assert Administrators membership - previously this ran only on
      # the create path, so an existing-but-non-admin account stayed unusable.
      if (-not (Get-LocalGroupMember -Group 'Administrators' -Member $User -ErrorAction SilentlyContinue)) {
        Add-LocalGroupMember -Group 'Administrators' -Member $User
      }
      Write-Output "Local admin account ready: $User"
    } catch {
      Write-Output "ERROR configuring local admin account: $($_.Exception.Message)"
    }

    # Local (non-domain) accounts are blocked from remote admin by UAC token
    # filtering; this is required for WinRM/NTLM administration to work.
    try {
      New-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System' `
        -Name 'LocalAccountTokenFilterPolicy' -Value 1 -PropertyType DWord -Force | Out-Null
    } catch { Write-Output "ERROR setting LocalAccountTokenFilterPolicy: $($_.Exception.Message)" }

    # --- 2. SSM agent (Session Manager access; non-fatal) ------------------------
    try {
      Set-Service -Name AmazonSSMAgent -StartupType Automatic
      Start-Service AmazonSSMAgent
    } catch { Write-Output "ERROR starting SSM agent: $($_.Exception.Message)" }

    # --- 3. WinRM over HTTPS (5986) for Ansible ---------------------------------
    # -SkipNetworkProfileCheck is required because EC2's NIC starts on the "Public"
    # profile, which otherwise blocks WinRM setup.
    try {
      Enable-PSRemoting -Force -SkipNetworkProfileCheck
      Set-Service -Name WinRM -StartupType Automatic
    } catch { Write-Output "ERROR enabling PSRemoting: $($_.Exception.Message)" }

    try {
      $cert = New-SelfSignedCertificate -DnsName $env:COMPUTERNAME -CertStoreLocation Cert:\LocalMachine\My
      Get-ChildItem WSMan:\localhost\Listener | Where-Object { $_.Keys -contains "Transport=HTTPS" } | Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
      New-Item -Path WSMan:\localhost\Listener -Transport HTTPS -Address * -CertificateThumbPrint $cert.Thumbprint -Force
    } catch { Write-Output "ERROR creating HTTPS listener: $($_.Exception.Message)" }

    # Require encryption; keep Negotiate/NTLM enabled (Ansible's ntlm transport).
    try {
      Set-Item -Path WSMan:\localhost\Service\Auth\Negotiate -Value $true
      Set-Item -Path WSMan:\localhost\Service\AllowUnencrypted -Value $false
      Set-Item -Path WSMan:\localhost\Shell\MaxMemoryPerShellMB -Value 2048
    } catch { Write-Output "ERROR setting WSMan options: $($_.Exception.Message)" }

    # Allow 5986 inbound at the OS firewall (the security group limits the source).
    try {
      New-NetFirewallRule -DisplayName "WinRM HTTPS 5986" -Direction Inbound -LocalPort 5986 -Protocol TCP -Action Allow -ErrorAction SilentlyContinue
    } catch { Write-Output "ERROR adding firewall rule: $($_.Exception.Message)" }

    try { Restart-Service WinRM } catch { Write-Output "ERROR restarting WinRM: $($_.Exception.Message)" }

    # --- 4. Self-verification: prove the account exists and is an administrator ---
    Write-Output "=== BOOTSTRAP VERIFICATION ==="
    Get-LocalUser -Name $User | Format-List Name,Enabled,PasswordExpires
    Get-LocalGroupMember -Group 'Administrators' | Format-Table Name
    Get-ChildItem WSMan:\localhost\Listener | ForEach-Object { $_.Keys }
    Write-Output "=== END VERIFICATION ==="

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
  description = "Windows workloads: all inbound from the VPC, all outbound"
  vpc_id      = var.vpc_id

  # Allow ALL inbound from within the VPC (every subnet range): RDP, WinRM (5986)
  # from the control node, AD/DNS host-to-host, etc. — without per-port rules.
  # Non-VPC inbound is dropped by the default deny. The bastions are NOT in this
  # group (they keep their own admin-CIDR-locked SGs), so they are excluded.
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
