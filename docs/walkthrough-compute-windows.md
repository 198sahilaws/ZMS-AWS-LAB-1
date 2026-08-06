# Code Walkthrough — `modules/compute-windows`

**Audience:** new engineer joining the ZMS AWS lab.
**Files covered (3):**

```
modules/compute-windows/main.tf
modules/compute-windows/variables.tf
modules/compute-windows/outputs.tf
```

**Prerequisite reading:** `docs/walkthrough-inventory-and-groupvars.md` (how the tags this
module writes become Ansible groups), `FIXES-SUMMARY.md` §T2.

---

## Why this module deserves the most careful reading

It provisions the Windows servers **and** their entire first-boot configuration. The embedded
PowerShell in `user_data` is the single densest piece of logic in the repo, and it is the
source of the longest-running bug in the project's history — one that produced a **misleading
error message pointing at the wrong subsystem** and cost multiple full rebuild cycles.

The one-paragraph version, so you have the context while reading:

> Windows applies **UAC remote token filtering** to local accounts. A local administrator that
> is *not* the built-in `Administrator` gets a **filtered token** when authenticating **over
> the network** — the Administrators SID is reduced to deny-only. WinRM's default ACL requires
> `BUILTIN\Administrators`, so the check fails and WinRM returns **401**, which Ansible
> surfaces as `ntlm: the specified credentials were rejected by the server`. RDP is unaffected
> because it's an **interactive** logon and gets the full token. Same account, same password,
> works for RDP, fails for WinRM. The fix is one registry value:
> **`LocalAccountTokenFilterPolicy = 1`**.

---

## 1. `main.tf` — `locals` block

### 1.1 Suffix and AZ count

```hcl
locals {
  sfx      = var.suffix == "" ? "" : "-${var.suffix}"
  az_count = length(var.subnet_ids)
```

**What it does.** `sfx` is a ternary: if `var.suffix` is empty, use `""`, else prepend a
hyphen. `az_count` counts the subnets passed in.

**Why.** Every resource name in the stack ends with a random 5–7 char suffix
(`ss-zms-windows-1-2orkan`) so repeated deploys into one account don't collide. The ternary
means the module still produces clean names if the suffix is disabled.

**⚠️ Gotcha.** `az_count` is used as a **divisor** in §1.2. If `subnet_ids` is ever an empty
list, `idx % 0` raises a division-by-zero at plan time. Nothing in this module validates it —
the root module is responsible for always passing at least one subnet.

### 1.2 The instance map — where roles become servers

```hcl
  instances = {
    for idx, role in var.windows_server_roles : tostring(idx + 1) => {
      subnet_index = idx % local.az_count
      role         = role
      # Both a writable DC and a read-only DC are domain controllers.
      is_dc = role == "dc" || role == "rodc"
    }
  }
```

**What it does.** A **for expression** producing a map. Iterating a list with two loop
variables gives `idx` (0-based position) and `role` (the value). `tostring(idx + 1)` makes the
key a **1-based string** — `"1"`, `"2"`, … Each value is an object with three attributes.

Given `windows_server_roles = ["dc", "rodc"]`:

```hcl
{
  "1" = { subnet_index = 0, role = "dc",   is_dc = true }
  "2" = { subnet_index = 1, role = "rodc", is_dc = true }
}
```

**Why a map keyed by index, not a `count`?** With `for_each` over a map, each instance has a
**stable identity** (`aws_instance.windows["1"]`). With `count`, removing the *first* element
of the list would renumber everything after it and Terraform would destroy and recreate
unrelated servers. Keys make the list order safe to edit at the tail.

**Business rule (plain English):** *The operator declares a **list of roles**; the list length
is the server count, and each entry's position determines which AZ that server lands in.*

**Round-robin placement:** `idx % az_count` spreads servers across AZs — server 0 → subnet 0,
server 1 → subnet 1, server 2 → subnet 0, and so on. With 2 subnets and 2 roles you get one
DC per AZ, which is the point for AD resilience.

**`is_dc` covers both DC flavours.** A read-only DC is still a domain controller, so both `dc`
and `rodc` get the `Domain_Controller=Enabled` tag (§4.3). This was widened when the `rodc`
role was introduced.

**📌 Stale comment.** The block comment above (lines 5–8) still says *"A `dc` role additionally
gets `Domain_Controller=Enabled`"* — it predates `rodc`. The inline comment on line 13 is
correct. Minor, but the two disagree.

**Practical consequence you will need.** These keys are how you address a single instance for
replacement:

```bash
terraform apply -replace='module.compute_windows.aws_instance.windows["1"]'
```

---

## 2. `main.tf` — the `user_data` PowerShell

This is the critical section. It is a Terraform **heredoc** (`<<-POWERSHELL ... POWERSHELL`)
containing a PowerShell script that EC2Launch v2 executes at first boot.

### 2.0 Two mechanisms you must understand before reading the script

**(a) Terraform interpolation vs. PowerShell variables.** Terraform substitutes **`${...}`**
only. Everything else passes through untouched:

| In the heredoc | Who evaluates it |
|---|---|
| `${var.windows_admin_username}` | **Terraform**, at plan time |
| `$User`, `$Pass`, `$cert` | **PowerShell**, at boot |
| `$env:COMPUTERNAME` | PowerShell |
| `$($_.Exception.Message)` | PowerShell (it's `$(` not `${`) |
| `$true`, `$false` | PowerShell |

**🔴 Editing hazard.** If you ever write PowerShell's `${...}` brace syntax in here — e.g.
`${env:COMPUTERNAME}` — **Terraform will try to interpolate it and fail** with an obscure
error about an unknown variable. Use `$env:COMPUTERNAME` (no braces), as the current code does.

**(b) `user_data` runs exactly once.** EC2Launch v2 executes it on **first boot only**, and
`<persist>false</persist>` explicitly opts out of re-running. See §3.3 for the crucial
consequence.

### 2.1 Transcript and error preference — the fix for the original bug

```powershell
Start-Transcript -Path "C:\Windows\Temp\winrm-bootstrap.log" -Append
$ErrorActionPreference = "Continue"
```

**What it does.** `Start-Transcript` records everything the script writes to a log file.
`$ErrorActionPreference` sets the default reaction to non-terminating errors; `"Continue"`
means *report and keep going*.

**Why — this is scar tissue.** The previous version set `$ErrorActionPreference = "Stop"`
**globally, on line 2**, which promotes every non-terminating error into a script-killing one.
Combined with the original ordering (SSM agent **before** account creation), a transient
failure touching the SSM service — which is genuinely likely, since it's still starting during
first boot — killed the script **before the admin account was created**.

And because EC2Launch v2 stands up its *own* 5986 HTTPS listener, the port still answered.
Ansible connected, sent credentials for an account that didn't exist, and got a 401 →
*"credentials were rejected"*. The error pointed at credentials; the actual fault was an
aborted bootstrap.

> **Note:** in the final diagnosis this abort was **not** what was happening on the live hosts
> — the transcript showed the script completing and the account existing. The true cause was
> `LocalAccountTokenFilterPolicy` (§2.3). But the fragility was real and is now removed.

**The transcript is the primary diagnostic artefact.** After any Windows bootstrap problem:

```powershell
Get-Content C:\Windows\Temp\winrm-bootstrap.log -Tail 40
```

### 2.2 Local admin account — created FIRST

```powershell
$User = '${var.windows_admin_username}'
$Pass = ConvertTo-SecureString '${var.windows_admin_password}' -AsPlainText -Force
try {
  if (Get-LocalUser -Name $User -ErrorAction SilentlyContinue) {
    Set-LocalUser -Name $User -Password $Pass -PasswordNeverExpires $true
  } else {
    New-LocalUser -Name $User -Password $Pass -PasswordNeverExpires -AccountNeverExpires
  }
  Enable-LocalUser -Name $User
  if (-not (Get-LocalGroupMember -Group 'Administrators' -Member $User -ErrorAction SilentlyContinue)) {
    Add-LocalGroupMember -Group 'Administrators' -Member $User
  }
  Write-Output "Local admin account ready: $User"
} catch {
  Write-Output "ERROR configuring local admin account: $($_.Exception.Message)"
}
```

**What it does.** Converts the plaintext password to a `SecureString`, then idempotently
ensures the account: reset the password if it exists, create it if not; enable it; add it to
Administrators if not already a member.

**Why each detail matters:**

- **Single quotes** around the interpolated values. PowerShell single-quoted strings are
  **literal** — no `$` expansion, no backtick escapes. With double quotes, a password
  containing `$` or a backtick would be silently mangled into something that doesn't match the
  secret. (Your current password `Zscaler@1234` is safe either way; the next one might not be.)
- **Ordering — this block is FIRST.** Everything else (SSM, WinRM) is downstream and
  non-critical by comparison. If a later stage fails, the host is still reachable.
- **The `if`/`else` makes it idempotent** across the create and reset paths.
- **`Enable-LocalUser` unconditionally** — a disabled account would authenticate-fail
  identically to a wrong password.
- **🔴 The Administrators check runs on BOTH paths.** In the previous version
  `Add-LocalGroupMember` sat *inside the `else` (create) branch only*. An account that already
  existed but wasn't an administrator would stay unusable forever — and WinRM's default ACL
  requires Administrators, so it would fail with the same misleading 401.
- **`try/catch` per stage** so an error is logged, not fatal.

**Business rule:** *Every Windows server gets one local administrator account (name and
password from tfvars), enabled, non-expiring, and guaranteed to be in the Administrators
group — asserted on every code path.*

### 2.3 🔴 `LocalAccountTokenFilterPolicy` — the actual root cause

```powershell
# Local (non-domain) accounts are blocked from remote admin by UAC token
# filtering; this is required for WinRM/NTLM administration to work.
try {
  New-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System' `
    -Name 'LocalAccountTokenFilterPolicy' -Value 1 -PropertyType DWord -Force | Out-Null
} catch { Write-Output "ERROR setting LocalAccountTokenFilterPolicy: $($_.Exception.Message)" }
```

**What it does.** Creates a DWORD registry value set to `1`. The trailing **backtick** is
PowerShell's line-continuation character. `-Force` overwrites an existing value. `| Out-Null`
discards the returned object so it doesn't clutter the transcript.

**Why — the full mechanism.** Windows UAC applies **remote token filtering** to local
accounts. When a local administrator that is *not* the built-in `Administrator` authenticates
**over the network**, Windows issues a **filtered token**: the `Administrators` SID is present
but marked *deny-only*. WinRM's default `RootSDDL` grants access to `BUILTIN\Administrators`,
the filtered token fails that check, and WinRM returns **HTTP 401**.

pywinrm reports a 401 as `ntlm: the specified credentials were rejected by the server` — a
message that is, in this situation, actively misleading. The credentials are correct.

**Why RDP kept working.** RDP is an **interactive** logon, which is not subject to remote
token filtering. It receives the full, unfiltered token. This asymmetry — *same account, same
password, RDP fine, WinRM refused* — is what made the bug so hard to pin down, and it's why
"the password must be wrong" was the wrong hypothesis for several rounds.

**Setting it to `1` disables the filtering for remote logons**, so the account arrives at WinRM
with its Administrators membership intact.

**Verified fix.** Setting this by hand on both live hosts made
`ansible os_windows -m win_ping` return `pong` immediately, with no other change.

**Security note, stated honestly.** This *is* a relaxation of a UAC hardening control. It's
required for local-account remote administration and is standard practice for
Ansible-managed Windows. The mitigations here are that the accounts are non-default-named,
the hosts have no public IPs, and inbound is limited to the VPC CIDR. In a domain-joined
production estate you'd prefer domain accounts + Kerberos and would not need this.

**Defence in depth.** `roles/baseline/tasks/windows.yml` re-asserts this value on **every
converge** via `win_regedit`, so it can't drift. Note the Ansible task can only *maintain* it
— it can't bootstrap it, because Ansible needs WinRM working to connect at all. That's
`user_data`'s job.

### 2.4 SSM agent — deliberately demoted

```powershell
try {
  Set-Service -Name AmazonSSMAgent -StartupType Automatic
  Start-Service AmazonSSMAgent
} catch { Write-Output "ERROR starting SSM agent: $($_.Exception.Message)" }
```

**What it does.** Ensures the SSM agent auto-starts and is running.

**Why it moved.** This block was **first** in the original script, immediately after
`$ErrorActionPreference = "Stop"`. The agent is often mid-startup during first boot, so
touching it can throw — and under `Stop` that killed everything downstream. It's now **third**
and wrapped in `try/catch`: SSM is a convenience (Session Manager access), not a prerequisite.

**Downstream use.** SSM is how you reach these hosts without RDP — including the
`aws ssm send-command` fallback for setting the registry value out-of-band.

### 2.5 WinRM over HTTPS

```powershell
try {
  Enable-PSRemoting -Force -SkipNetworkProfileCheck
  Set-Service -Name WinRM -StartupType Automatic
} catch { ... }

try {
  $cert = New-SelfSignedCertificate -DnsName $env:COMPUTERNAME -CertStoreLocation Cert:\LocalMachine\My
  Get-ChildItem WSMan:\localhost\Listener | Where-Object { $_.Keys -contains "Transport=HTTPS" } | Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
  New-Item -Path WSMan:\localhost\Listener -Transport HTTPS -Address * -CertificateThumbPrint $cert.Thumbprint -Force
} catch { ... }
```

**What it does.** Enables PowerShell remoting, generates a self-signed certificate, removes any
pre-existing HTTPS listener, and creates a new one bound to that certificate.

**Why each flag:**

- **`-SkipNetworkProfileCheck`** — EC2's NIC starts on the **Public** network profile, and
  `Enable-PSRemoting` refuses to configure remoting on a Public profile without this flag.
  Without it, remoting setup fails on every EC2 instance.
- **Remove-then-create** — EC2Launch v2 may already have created its own 5986 listener. Rather
  than detect and reconcile, the script removes any HTTPS listener and creates a known one
  bound to a certificate whose thumbprint it controls.
- **`$_.Keys -contains "Transport=HTTPS"`** — WSMan listener objects expose a `Keys` collection
  of `Name=Value` selector strings; this is the idiomatic way to filter by transport.

**Gotcha — the certificate is self-signed and CN'd to the computer name**, but Ansible connects
**by private IP**. Both the trust chain and the CN would fail validation, which is exactly why
`group_vars/os_windows.yml` sets `ansible_winrm_server_cert_validation: ignore`. These two
files are coupled: making the cert trusted here without changing that setting achieves nothing.

### 2.6 WSMan service options

```powershell
try {
  Set-Item -Path WSMan:\localhost\Service\Auth\Negotiate -Value $true
  Set-Item -Path WSMan:\localhost\Service\AllowUnencrypted -Value $false
  Set-Item -Path WSMan:\localhost\Shell\MaxMemoryPerShellMB -Value 2048
} catch { ... }
```

**What it does.** Enables Negotiate (NTLM/Kerberos) auth, forbids unencrypted traffic, and
raises the per-shell memory ceiling to 2 GB.

**Why.** `Negotiate` is what `ansible_winrm_transport: ntlm` requires. `AllowUnencrypted =
$false` is safe because we're on HTTPS. The memory ceiling matters because Ansible's PowerShell
modules are large; the 150 MB default causes OOM failures on bigger modules (notably the AD
ones).

### 2.7 Firewall and restart

```powershell
try {
  New-NetFirewallRule -DisplayName "WinRM HTTPS 5986" -Direction Inbound -LocalPort 5986 -Protocol TCP -Action Allow -ErrorAction SilentlyContinue
} catch { ... }
try { Restart-Service WinRM } catch { ... }
```

**What it does.** Opens 5986 inbound at the **Windows** firewall and restarts WinRM so the
listener and auth changes take effect.

**Why both firewalls matter.** There are two layers: the AWS **security group** (which allows
all inbound from the VPC CIDR — see §3.2) and the **Windows firewall** on the host. Both must
permit 5986. A newcomer debugging connectivity usually checks only the security group.

**Gotcha.** Re-running would create a duplicate rule; `-ErrorAction SilentlyContinue` swallows
that. Not an issue in practice since `user_data` runs once.

### 2.8 Self-verification block

```powershell
Write-Output "=== BOOTSTRAP VERIFICATION ==="
Get-LocalUser -Name $User | Format-List Name,Enabled,PasswordExpires
Get-LocalGroupMember -Group 'Administrators' | Format-Table Name
Get-ChildItem WSMan:\localhost\Listener | ForEach-Object { $_.Keys }
Write-Output "=== END VERIFICATION ==="
```

**What it does.** Prints the account state, Administrators membership, and active listeners
into the transcript.

**Why it exists.** Added specifically because the earlier failure mode was **invisible**. When
the bootstrap silently skipped account creation, nothing on the box said so — the only symptom
was a misleading auth error from a machine 30 minutes away. This block turns "did the bootstrap
work?" into a single `Get-Content` on the host.

**Business rule:** *First-boot configuration must prove it succeeded, in a log on the host,
rather than leaving diagnosis to a downstream error message.*

---

## 3. `main.tf` — the resources

### 3.1 AMI lookup

```hcl
data "aws_ssm_parameter" "ami" {
  name = var.windows_ami_ssm_parameter
}
```

**What it does.** Reads an AWS-published SSM public parameter that always points at the latest
AMI ID for a given Windows version.

**Why.** AMI IDs are **region-specific and change monthly**. Hardcoding one pins you to a
stale image and breaks the stack in other regions. The parameter path
(`/aws/service/ami-windows-latest/Windows_Server-2022-English-Full-Base`) resolves correctly in
any region.

**⚠️ Gotcha.** Because the parameter tracks *latest*, a `terraform plan` months later may show
an AMI change and want to **replace your instances**. That's inherent to this approach. If you
need immutability, pin an explicit AMI ID instead.

### 3.2 Security group

```hcl
resource "aws_security_group" "windows" {
  ingress {
    description = "All inbound from within the VPC"
    from_port = 0
    to_port   = 0
    protocol  = "-1"
    cidr_blocks = [var.vpc_cidr]
  }
  egress { ... 0.0.0.0/0 ... }
}
```

**What it does.** `protocol = "-1"` means **all protocols**; with `-1`, the port range is
ignored. One rule in, one rule out.

**Why — this was a deliberate simplification.** It replaced a set of per-port rules (RDP from
bastion SG, WinRM 5986 from control SG, RDP from VPC, plus 80/443 egress). Those rules kept
producing gaps: WinRM blocked, AD east-west traffic blocked, package downloads blocked on port
80. AD alone needs LDAP 389, Kerberos 88, DNS 53, SMB 445 and a wide dynamic RPC range —
enumerating them correctly is genuinely hard.

**Business rule:** *Managed hosts accept all traffic from inside the VPC and may reach
anywhere outbound. Non-VPC inbound is dropped by AWS's implicit deny. The bastions are NOT in
this group — they keep their own SGs locked to admin CIDRs.*

**Security assessment, honestly.** This is more permissive than per-port rules and provides no
lateral-movement containment *within* the VPC. It's appropriate for a lab, and the perimeter
(no public IPs, default-deny from outside) still holds. For production you'd reintroduce
scoped rules — and should expect the AD port set to be the painful part.

### 3.3 The instance resource

```hcl
resource "aws_instance" "windows" {
  for_each = local.instances

  ami                    = data.aws_ssm_parameter.ami.value
  instance_type          = var.instance_type
  subnet_id              = var.subnet_ids[each.value.subnet_index]
  vpc_security_group_ids = [aws_security_group.windows.id]
  iam_instance_profile   = var.iam_instance_profile
  user_data              = local.user_data
```

**What it does.** `for_each` over the map creates one instance per entry, with `each.key`
(`"1"`) and `each.value` (the object) available inside.

**🔴 The most important operational fact in this module.** Changing `user_data` on an existing
instance triggers only a **stop/start** by default — *not* a replacement. And because
`user_data` executes on **first boot only**, a stop/start means **the new script never runs**.

You would see a successful `terraform apply` reporting "1 changed", the instance reboot, and
**identical behaviour**. To actually apply a `user_data` change:

```bash
terraform apply -replace='module.compute_windows.aws_instance.windows["1"]' \
                -replace='module.compute_windows.aws_instance.windows["2"]'
```

*(The alternative is setting `user_data_replace_on_change = true` on the resource, which makes
Terraform recreate automatically. Not currently set — **reason unclear / worth considering**,
since the current behaviour is a trap.)*

```hcl
  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 1
  }
```

**What it does.** Enforces **IMDSv2** (`http_tokens = "required"` — a session token is
mandatory) and limits the metadata response hop limit to 1.

**Why.** IMDSv1's simple GET was exploitable via SSRF; IMDSv2's token requirement blocks that
class of attack. `hop_limit = 1` prevents containers on the host from reaching IMDS.

**Downstream dependency.** `collect-debug.sh` probes IMDS with the two-step
PUT-token-then-GET flow precisely because v1 is disabled here.

```hcl
  root_block_device {
    volume_size = var.root_volume_size
    volume_type = "gp3"
    encrypted   = true
    kms_key_id  = var.kms_key_id
    tags        = merge(var.tags, { Name = "...-root..." })
  }
```

**What it does.** Encrypted gp3 root volume, separately tagged.

**Why.** `encrypted = true` is unconditional — encryption at rest is not optional.
`kms_key_id = null` falls back to the account default EBS key, so the module works whether or
not a customer-managed key was created.

### 3.4 Tags — the Terraform → Ansible contract

```hcl
  tags = merge(
    var.tags,
    {
      Name = "${var.name_prefix}-windows-${each.key}${local.sfx}"
      OS   = "windows"
      Role = each.value.role
    },
    each.value.is_dc ? { Domain_Controller = "Enabled" } : {},
  )
```

**What it does.** `merge()` combines maps left-to-right; later keys win. The final argument is a
ternary yielding either a one-key map or an **empty map** — a conditional tag.

**Why this is the most important block in the file for Ansible.** These tags *are* the
interface:

| Tag | Value | Becomes | Consumed by |
|---|---|---|---|
| `OS` | `windows` | group `os_windows` | WinRM connection settings |
| `Role` | `dc` / `rodc` / `web` … | group `role_dc`, `role_rodc`, … | which playbooks target the host |
| `Domain_Controller` | `Enabled` (conditional) | *(no group)* | informational / console filtering |
| `ManagedBy` | `Terraform` (from `var.tags`) | inventory **filter** | decides if Ansible sees it at all |

**Business rule:** *A Windows server's role tag determines which playbooks apply to it. DC and
RODC roles are additionally flagged with `Domain_Controller=Enabled`.*

**⚠️ Gotcha — `Domain_Controller` creates no inventory group.** Only `OS`, `Distro`, `Role` and
`Environment` have `keyed_groups` rules in `inventory/aws_ec2.yml`. Playbooks target
`role_dc` / `role_rodc`, never `Domain_Controller`. The tag is for humans and console filters.

**⚠️ Gotcha — no `Distro` tag here.** `compute-linux` sets `Distro` (driving the SSH login
user); Windows doesn't need it because the WinRM username comes from Secrets Manager. So
`distro_*` groups contain only Linux hosts — don't intersect a Windows playbook with one.

---

## 4. `variables.tf`

Most variables are self-explanatory. Three deserve comment, and **two are dead**.

### 4.1 `sensitive = true` on the username

```hcl
variable "windows_admin_username" {
  type      = string
  sensitive = true
}
variable "windows_admin_password" {
  type      = string
  sensitive = true
}
```

**What it does.** Marks both values so Terraform redacts them from plan/apply output and any
output referencing them.

**Why mark the *username* sensitive?** Defensible (it's half a credential), but it has a
downstream cost: anything consuming it must call `nonsensitive()` — which the root module does
in the connection-details template. **Whether that trade-off was deliberate is not inferable
from the code — needs confirmation from the original author.**

**🔴 Security reality you must know.** The password is interpolated into `user_data`, and
**EC2 stores `user_data` in plaintext instance metadata**. Anyone who can call
`ec2:DescribeInstanceAttribute`, or any process on the instance that can reach IMDS, can read
the local administrator password. Terraform's `sensitive` flag protects the *console output*,
not the *instance metadata*.

This is inherent to configuring a Windows admin account via `user_data`. If that's
unacceptable, the alternatives are to have the instance fetch the password from Secrets
Manager itself using its instance role, or to bake it into an AMI. **Worth an explicit
decision rather than an assumption.**

### 4.2 `windows_server_roles` — weaker validation than the root

```hcl
variable "windows_server_roles" {
  type    = list(string)
  default = ["dc", "web"]
  validation {
    condition     = length(var.windows_server_roles) >= 2
    error_message = "Provide at least 2 windows_server_roles ..."
  }
}
```

**What it does.** Only enforces "at least 2".

**Gotcha — the real validation lives in the root `variables.tf`**, which additionally enforces
2–10 entries, an allowed-value set (`dc`, `rodc`, `fileshare`, `web`, `client`), and **at least
one `dc`**. Using this module standalone would bypass all of that and let a typo like `"dcc"`
through, producing a `role_dcc` group no playbook targets — a silent no-op.

**📌 Stale description.** It still says *'A server whose role is "dc" also gets
`Domain_Controller=Enabled`'* — `rodc` does too, as of the `is_dc` change.

### 4.3 🔴 Dead variables

```hcl
variable "bastion_security_group_id" {
  description = "Bastion SG ID; Windows instances accept RDP (3389) from this SG (in addition to the VPC range). ..."
  default     = null
}

variable "control_security_group_id" {
  description = "Ansible control-node SG ID. When set, Windows instances accept WinRM HTTPS (5986) from it (push). ..."
  default     = null
}
```

**Status: DEAD. Neither is referenced anywhere in `main.tf`.**

They were used by the per-port security-group rules that the §3.2 simplification removed. The
root module still passes values for them, so nothing errors — but:

- The **descriptions are now actively wrong.** They describe port-scoped behaviour that no
  longer exists, which will mislead the next reader into thinking RDP/WinRM access is
  SG-scoped when it's actually VPC-CIDR-wide.
- `vpc_cidr`'s description has the same problem: *"RDP is allowed from this range / the bastion
  only, never the internet"* — it's now **all** traffic from that range, not just RDP.

**Recommend:** delete the two dead variables (and the root's corresponding arguments), and
rewrite `vpc_cidr`'s description. Left in place, they are a trap.

---

## 5. `outputs.tf`

```hcl
output "instance_ids"  { value = { for k, i in aws_instance.windows : k => i.id } }
output "private_ips"   { value = { for k, i in aws_instance.windows : k => i.private_ip } }
output "public_ips"    { value = { for k, i in aws_instance.windows : k => i.public_ip } }
output "security_group_id" { value = aws_security_group.windows.id }
```

**What it does.** For-expressions over the instance map, producing `{"1" = ..., "2" = ...}`.

**Note on `public_ips`.** These instances are in private subnets with no public IP, so this map
is all empty strings. It exists for interface symmetry with `compute-linux` and for the
connection-details template, which renders the same fields for every host.

```hcl
output "dns_records" {
  value = { for k, i in aws_instance.windows : "win-${k}" => i.private_ip }
}
```

**What it does.** Re-keys the map with a `win-` prefix.

**Why.** The root module merges DNS records from several sources (bastion, Linux, Windows,
control node) into one map for `modules/dns`. Without prefixes, Windows `"1"` and Linux `"1"`
would collide and one would silently overwrite the other. Prefixing namespaces them —
`win-1.alcor.co.in`.

```hcl
output "instances_detail" {
  value = {
    for k, i in aws_instance.windows : k => {
      name = i.tags["Name"]
      instance_id = i.id
      subnet_id = i.subnet_id
      az = i.availability_zone
      private_ip = i.private_ip
      public_ip = i.public_ip
    }
  }
}
```

**What it does.** A richer per-instance object.

**Why.** Feeds `templates/connection-details.tftpl`, which renders the human-readable
`connection-details.txt` written on every apply. `i.tags["Name"]` reads back the computed tag
rather than recomputing the name string — one source of truth.

**Gotcha.** `connection-details.txt` is **gitignored** — it contains host inventory detail. Do
not commit it.

---

## Glossary additions

| Term | Meaning |
|---|---|
| **`user_data`** | Script passed at launch; on Windows executed by EC2Launch v2 on **first boot only**. |
| **EC2Launch v2** | The Windows launch agent. Notably creates its **own** WinRM HTTPS listener on 5986 — which can mask a failed bootstrap. |
| **UAC remote token filtering** | Windows security feature giving local admins a *filtered* (deny-only Administrators) token over the network. Defeated by `LocalAccountTokenFilterPolicy=1`. |
| **`LocalAccountTokenFilterPolicy`** | Registry DWORD under `...\Policies\System`. `1` = local admins get full tokens remotely. **The fix for the WinRM 401.** |
| **`RootSDDL`** | WinRM's access-control descriptor. Defaults to requiring `BUILTIN\Administrators`. |
| **IMDSv2** | Session-based instance metadata (PUT token, then GET with header). Enforced via `http_tokens = "required"`. |
| **`for_each` key** | Stable per-instance identity (`"1"`, `"2"`). Used in `-replace` addressing. |
| **Round-robin AZ placement** | `idx % az_count` — server *i* lands in `subnet_ids[i % az_count]`. |

---

## Flagged issues

1. **🔴 Dead variables with misleading descriptions.** `bastion_security_group_id` and
   `control_security_group_id` are unreferenced after the SG simplification, and their
   descriptions still claim port-scoped RDP/WinRM behaviour that no longer exists.
   `vpc_cidr`'s description is stale for the same reason. **Delete the dead pair; fix the
   description.**

2. **🔴 `user_data` changes require `-replace`.** Default behaviour is stop/start, and
   `user_data` only runs on first boot — so a `terraform apply` reports success while changing
   nothing. Consider `user_data_replace_on_change = true`. **Reason for its absence unclear.**

3. **The admin password is readable from instance metadata.** Inherent to this approach;
   `sensitive = true` does not protect it there. Flagged so it's a decision, not an oversight.

4. **Module-level validation is weaker than the root's.** Only `>= 2` here; allowed values,
   the 2–10 range and the "must include a dc" rule live in the root. This module is not safe
   to use standalone.

5. **Two stale comments/descriptions re `rodc`:** the `locals` block comment and the
   `windows_server_roles` description both predate RODC support and mention only `dc`.

6. **`az_count` can be zero** if `subnet_ids` is empty, causing a division-by-zero at plan
   time. No guard in this module.

7. **SG rule is permissive by design** (all inbound from the VPC CIDR). Documented as a
   deliberate lab trade-off, but re-evaluate before any production use — particularly the
   absence of lateral-movement containment.
