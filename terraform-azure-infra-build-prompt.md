# Build Prompt — Modular, Secure Azure Infrastructure in Terraform + Ansible

> Paste everything below into your coding agent (Claude, Cursor, etc.). It is a complete, self-contained specification for an **Azure** replica of the ZMS AWS lab: a modular, variable-driven Terraform stack that provisions a private VM estate plus an Ansible **push** control node, which configures the estate over SSH (Linux) and WinRM (Windows) using a dynamically discovered inventory and a single consolidated secret in Azure Key Vault.

---

## Role

You are a **senior DevOps / Platform engineer**. You write production-grade, idiomatic Terraform and Ansible. You favour small reusable modules, explicit variables over hardcoded values, least-privilege identity (Managed Identity + Azure RBAC), and infrastructure that is auditable and repeatable.

## Objective

Build a **highly modular, customizable, and secure Azure** infrastructure in Terraform, plus an **Ansible push-based control node** that manages the estate. Every meaningful value must be driven by input variables with sensible, documented defaults. Names must follow a custom convention with a random suffix, and an arbitrary `tags` map must be applied consistently to every resource. Software configuration on Windows and Linux VMs is handled **entirely by Ansible** (not a cloud-native tool), running from an in-VNet control node.

## AWS → Azure service mapping (use these equivalents)

| Concern | AWS (source lab) | Azure (build this) |
|---|---|---|
| Network | VPC | Virtual Network (VNet) |
| Segmentation | Subnets | Subnets |
| Outbound egress | NAT Gateway (per-AZ) | **Azure NAT Gateway** per zone + Standard Public IP (Azure default outbound is retiring — attach NAT GW explicitly) |
| Firewalling | Security Groups (SG-to-SG) | **Network Security Groups (NSG)** + **Application Security Groups (ASG)** for "SG-to-SG"-style rules |
| Routing | Route Tables | Route Tables (UDR) |
| Compute | EC2 instance | Virtual Machine (VM) |
| Image | AMI / SSM public parameter | Marketplace image (`publisher/offer/sku/version`) |
| SSH key | `tls_private_key` + `aws_key_pair` | `tls_private_key` + VM `admin_ssh_key` |
| Private DNS | Route 53 private hosted zone | **Azure Private DNS Zone** + VNet link + A records |
| Disk encryption | KMS on EBS | Platform-managed keys by default; optional **Disk Encryption Set + Key Vault key** (customer-managed) |
| Secrets | Secrets Manager | **Azure Key Vault** (RBAC mode) |
| Identity | IAM role + instance profile | **Managed Identity** (user-assigned) + **Azure RBAC** role assignments |
| Bastion | Ubuntu bastion VM | Self-managed **Ubuntu jump VM** (faithful) — note Azure Bastion service as an alternative |
| Object store | S3 artifact bucket | **Storage Account + Blob container** |
| Dynamic inventory | `amazon.aws.aws_ec2` | `azure.azcollection.azure_rm` |
| Secret lookup | `amazon.aws.aws_secret` | `azure.azcollection.azure_keyvault_secret` (via Managed Identity) |
| Region default | `eu-west-3` | `location` default e.g. `francecentral` or `westeurope` |
| State backend | local filesystem | local filesystem (same) |

> **Amazon Linux has no Azure equivalent.** Map the "two Linux distros (Amazon Linux + Ubuntu)" split to **Ubuntu + a RHEL-family distro** (RHEL, Rocky, or AlmaLinux). This preserves the meaningful difference the playbooks depend on: `apt` vs `dnf`, keyed off `ansible_os_family`. Use `Distro` tag values `ubuntu` and `rhel`.

## Design principles (apply throughout)

1. **Modularity** — Independent, reusable modules. No module reaches into another's internals; pass values via inputs/outputs only. Avoid provider→resource dependency cycles by putting all name/tag derivation in a resourceless `naming` module (locals).
2. **Variable-driven** — No magic strings, CIDRs, image refs, sizes, or counts. Everything configurable via `variables.tf` with types, descriptions, defaults. Provide `terraform.tfvars.example`. The stack must deploy with **only `terraform.tfvars` edits** — no source changes to customise names, tags, sizes, CIDRs, or counts.
3. **Custom naming + random suffix** — A single convention produces every name: `{name_prefix}-{environment}-{component}-{suffix}`. `suffix` is a **5–7 character lowercase-alphanumeric `random_string`** appended to every resource name (length variable-controlled, validated 5–7). Note Key Vault and Storage Account names are globally unique and length-limited — build compliant names from the same suffix.
4. **Consistent multi-tagging** — Accept a `tags` map (any number of key/values). The **AzureRM provider has no `default_tags`**, so merge a standard tag set (`Environment`, `Owner`, `Project`, `CostCenter`, `ManagedBy=Terraform`) with the user map in the `naming` module and apply the merged map to **every** resource's `tags` argument. Ansible discovery depends on `ManagedBy=Terraform` (capital T) being present on every managed VM.
5. **Security first** — Private-by-default VMs (no public IPs on workloads). The **only** internet-facing entry point is the bastion; its SSH (22) ingress is locked to a `bastion_allowed_cidrs` variable. Linux workloads accept SSH only from the bastion/control ASG; Windows workloads accept RDP and WinRM only from the bastion/VNet/control ASG, never the internet. Encrypt disks, mark the Windows password and generated private key `sensitive`, store no secrets in code, and give the control node a Managed Identity scoped to exactly the one secret it reads.
6. **Clean state & versions** — Pin `required_version >= 1.5` and providers. Use a **local** backend (overridable).

## Repository / module structure (produce this)

```
.
├── main.tf                 # root: wires modules together
├── variables.tf            # all root inputs
├── outputs.tf              # key outputs (VNet id, subnet ids, VM ids, private/public IPs, zone id, KV uri)
├── providers.tf            # azurerm (features {}) + azuread/tls/local/random providers
├── versions.tf             # required_version + required_providers
├── terraform.tfvars.example
├── README.md               # usage, inputs, outputs, connection + Ansible workflow, HLD diagram
├── .gitignore              # ignore *.pem, *.tfstate*, .terraform/, connection-details.txt
├── .gitattributes          # normalize text to LF (scripts/YAML must be LF on the Linux control node)
├── templates/
│   └── connection-details.tftpl
└── modules/
    ├── naming/             # resourceless: standardized names + merged tags (locals)
    ├── network/            # VNet, subnets, NAT Gateways, route tables, NSGs, ASGs
    ├── dns/                # Private DNS zone + VNet link + A records (one per VM)
    ├── keypair/            # tls_private_key + local .pem + terraform_data perms fix
    ├── identity/           # user-assigned Managed Identity + RBAC role assignments
    ├── keyvault/           # Key Vault (RBAC) + ONE consolidated secret
    ├── bastion/            # Ubuntu jump VM in a public subnet (SSH entry point)
    ├── compute-linux/      # Ubuntu + RHEL-family VMs, role lists, ASG, MI
    ├── compute-windows/    # Windows Server VMs, WinRM enablement, role lists, ASG, MI
    └── ansible-control/    # control-node VM + custom_data (cloud-init) + MI wiring
```

Each module has its own `variables.tf`, `outputs.tf`, `main.tf`.

## Required infrastructure

### Networking (`modules/network`)
- **1 VNet** — address space from a variable (default e.g. `10.0.0.0/16`).
- **2 Availability Zones** — spread subnets/VMs across two zones for HA.
- **1 public subnet** (per-zone hosting for the bastion) routed for inbound; **1 NAT Gateway per zone** (each with a Standard Public IP) providing **outbound** for the private subnets.
- **Private subnet for app VMs** (per zone), associated with the zone-local NAT Gateway for egress.
- **Private "management" subnet** hosting the **Ansible control node** (single management subnet, associated with NAT for egress).
- Optional **AKS-reserved private subnet(s)** for future use, tagged appropriately.
- Subnet prefixes derived from the VNet space via `cidrsubnet()` and/or variables.
- **NSGs**: private-by-default. Use **Application Security Groups** to express "from the bastion" / "from the control node" rules without hardcoding IPs. Provide route tables (UDR) as needed for deterministic egress.

### Private DNS (`modules/dns`)
- **Azure Private DNS Zone** (name from a variable, e.g. `internal.example.local`) linked to the VNet.
- **A records for every VM**, generated dynamically from each VM's private IP so adding a VM auto-registers it. Include a `force_destroy`-style toggle so `terraform destroy` cleans records.

### SSH key pair (`modules/keypair`)
- Generate a fresh key with `tls_private_key` (RSA 4096 or ED25519). Attach the public key to Linux VMs via `admin_ssh_key`.
- Write the private key to `${path.root}/<name>.pem` with `file_permission = "0600"` **and** repair OS permissions with a `terraform_data` + `local-exec` provisioner: **`icacls` on Windows** (`/inheritance:r /grant:r "$($env:USERNAME):(R)"`) and **`chmod 600` on Linux/macOS**. Detect Windows via `substr(pathexpand("~"),0,1) != "/"`. This makes the key usable by OpenSSH on every OS.
- The same private key is also stored inside the consolidated Key Vault secret (below) so the control node can write it locally for its own outbound SSH.

### Identity & RBAC (`modules/identity`)
- Create a **user-assigned Managed Identity** for the **control node**.
- Role assignments (least privilege):
  - **Reader** on the resource group (so the `azure_rm` dynamic inventory can enumerate VMs).
  - **Key Vault Secrets User** scoped to the **one consolidated secret** (or the vault) so the control node can read only what it needs.
- Optionally create (empty) user-assigned identities for workload VMs for future use.

### Key Vault & consolidated secret (`modules/keyvault`)
- **1 Key Vault** in **RBAC authorization mode** (globally-unique name from the suffix; enable soft-delete; purge-protection variable-controlled).
- **ONE consolidated secret per deployment** holding a single JSON document. Terraform populates it from `terraform.tfvars` when `populate_ansible_secret = true`; otherwise create the empty container and set the value out-of-band. Keys:
  ```json
  {
    "ssh_private_key": "<PEM>",
    "winrm_username": "...",
    "winrm_password": "...",
    "provision_key": "<ZMS enforcer nonce>",
    "dsrm_password": "...",
    "domain_join_username": "...",
    "domain_join_password": "...",
    "mysql_root_password": "..."
  }
  ```
- Grant the control node's Managed Identity `get` on this secret. **No secret material is ever written to Git or to the control node's disk config** — only the secret's *name/URI* is injected (below).

### Bastion (`modules/bastion`)
- **1 × Ubuntu jump VM** in a **public subnet** with a Standard Public IP, using the generated SSH key.
- Size, image (Ubuntu 24.04 LTS marketplace), and subnet variable-driven; encrypted OS disk.
- NSG: inbound **SSH (22) only from `bastion_allowed_cidrs`**; egress to the VNet so it can reach private hosts. Single human jump host. (Document Azure Bastion service as a managed alternative.)

### Linux compute (`modules/compute-linux`)
Deploy into the **private app subnets**, no public IPs, encrypted OS disks, the generated SSH key, and an attached Managed Identity:
- **Role-list driven, minimum 2 per distro.** Accept `ubuntu_server_roles` and `rhel_server_roles` as **lists of lowercase roles** (list length = VM count, validated `>= 2`). Canonical roles: `dc`, `web`, `db`, `fileserver`, `client`. Round-robin VMs across the two zones (`vm i → zone[i % 2]`).
- Each VM gets tags: `OS=linux`, `Distro=<ubuntu|rhel>`, `Role=<value>`, plus the standard/merged set. `Role` becomes the `role_<value>` Ansible group; `Distro` drives `apt` vs `dnf`.
- NSG/ASG: inbound **SSH (22) only from the bastion ASG and the control-node ASG**; egress via NAT for public package repos.
- `admin_username` uniform (default `azureuser`) and variable-controlled. (Azure lets you set one admin user for all Linux VMs — simpler than the AWS `ec2-user`/`ubuntu` split — but still expose it per-distro for parity.)

### Windows compute (`modules/compute-windows`)
Deploy into the **private app subnets**, no public IPs, encrypted OS disks, attached Managed Identity:
- **Role-list driven, minimum 2.** Accept `windows_server_roles` (list, validated `>= 2`). A VM whose role is `dc` **also** gets tag `Domain_Controller=Enabled`. Round-robin across zones.
- Tags: `OS=windows`, `Role=<value>`, plus standard set (and `Domain_Controller=Enabled` for the DC).
- **Admin credentials as `sensitive` variables** (`windows_admin_username`, `windows_admin_password`); set the local admin via `custom_data`/PowerShell on first boot.
- **Enable WinRM over HTTPS (5986) for Ansible** via the first-boot PowerShell: `Enable-PSRemoting -Force -SkipNetworkProfileCheck`, create a self-signed cert, bind a 5986 HTTPS listener, allow 5986 at the OS firewall, disable unencrypted, raise `MaxMemoryPerShellMB`.
- NSG/ASG: inbound **RDP (3389)** from bastion/VNet and **WinRM (5986)** from the control-node ASG only; never the internet.

### Ansible control node (`modules/ansible-control`)
- **1 × Ubuntu VM** in the **management subnet**, no public IP, with the **user-assigned Managed Identity** attached and a persistent data disk for the repo.
- **Ordering:** the Key Vault + consolidated secret and the Managed Identity's role assignments must exist **before** the control node so the injected values are valid at first boot.
- **`custom_data` (cloud-init)** installs `git`, Python, Ansible, and the `azure.azcollection` Python deps; clones the control repo (`control_repo_url`); writes `/etc/ansible/estate.env`; installs and enables the systemd timers. The env file carries **names, not secrets**:
  ```
  AZURE_KEYVAULT_URL=https://<vault>.vault.azure.net/
  ANSIBLE_SECRET_NAME=<consolidated-secret-name>
  AZURE_SUBSCRIPTION_ID=<sub>
  AZURE_RESOURCE_GROUP=<rg>          # scope for the azure_rm inventory
  ANSIBLE_AZURE_AUTH_SOURCE=msi      # authenticate via the attached Managed Identity
  CONTROL_REPO_DIR=/opt/control-repo
  ```
- cloud-init must also **create `/var/log/ansible` owned by the service user** and make the private-key directory readable by that user.

## Software management decision — Ansible push (implement this)

Do **not** use a cloud-native config tool. Configuration is managed by **Ansible in push mode** from the in-VNet control node, because it is the same portable model across clouds and gives full desired-state control. The control node connects **out** to managed VMs — **SSH** for Linux, **WinRM/HTTPS (5986)** for Windows — over private addressing. Human interactive access (bastion/RDP) stays a separate concern from configuration.

## The Ansible control repository (rewrite for Azure — produce this)

```
control-repo/
  ansible.cfg            # inventory path, roles/collections, become (linux), forks, logging
  requirements.yml       # collections (pinned)
  site.yml               # estate push: pre-flight + Linux play + Windows play
  bootstrap.yml          # control-node self-config: collections + write SSH key from KV secret
  local.yml              # ansible-pull shim (imports bootstrap.yml)
  inventory/azure_rm.yml # DYNAMIC inventory via azure.azcollection.azure_rm (MSI auth)
  group_vars/
    all.yml              # KV url + secret name from env; field-scoped secret lookups
    os_linux.yml         # ssh + become(sudo) + admin user
    os_windows.yml       # winrm 5986, ntlm, cert ignore, creds via inline KV lookup, ansible_become:false
    distro_ubuntu.yml    # ansible_group_priority + login user  (apt)
    distro_rhel.yml      # ansible_group_priority + login user  (dnf)
  roles/baseline/        # cross-OS baseline (timezone, chrony, base packages)
  playbooks/
    ubuntu-setup.yml ubuntu-apache2.yml ubuntu-mysql.yml
    rhel-setup.yml   rhel-httpd.yml     rhel-mysql.yml
    windows-adds.yml windows-domain-join.yml windows-iis.yml
    windows-python.yml windows-share.yml windows-zms-enforcer.yml
  scripts/reconverge.sh notify-result.sh
  systemd/ansible-bootstrap.{service,timer} ansible-estate.{service,timer} estate.env.example
  .gitattributes .gitignore .ansible-lint .yamllint .pre-commit-config.yaml
```

### Dynamic inventory (`inventory/azure_rm.yml`)
- Plugin `azure.azcollection.azure_rm`; authenticate via the Managed Identity (`auth_source: msi`).
- Scope to the resource group(s) via `include_vm_resource_groups`; **only include VMs tagged `ManagedBy=Terraform`** (use `conditional_groups`/`default_host_filters` to exclude anything else).
- Set `ansible_host` to the VM's **private IP**; the control node is in-VNet.
- `keyed_groups` from tags: `OS → os_*`, `Distro → distro_*`, `Role → role_*`, `Environment → env_*` (mirrors the AWS design so plays and connection `group_vars` attach by group).

### Secrets — field-scoped, no bundle variable (`group_vars`)
- `all.yml` reads only the **secret name + vault URL** from the injected env; it does **not** bind the whole secret to a variable.
- Every consumer resolves **only the one field it needs, inline, at point of use**, e.g.:
  ```yaml
  ansible_password: "{{ (lookup('azure.azcollection.azure_keyvault_secret', ansible_secret_name, vault_url=azure_keyvault_url) | from_json).winrm_password }}"
  ```
- Sensitive tasks use `no_log: true`. This keeps the SSH key + passwords out of any global scope (no `-vvv`/`debug` leak).

### Connection group_vars
- `os_linux.yml`: `ansible_connection: ssh`, `ansible_become: true` (sudo), admin user.
- `distro_ubuntu.yml` / `distro_rhel.yml`: `ansible_group_priority: 10` so the distro group wins over `os_linux` (otherwise alphabetical merge lets `os_linux` clobber it); set the login user and any per-distro vars. (On Azure the admin user is uniform, but keep this pattern for parity and future divergence.)
- `os_windows.yml`: `ansible_connection: winrm`, `ansible_port: 5986`, `ansible_winrm_transport: ntlm`, `ansible_winrm_server_cert_validation: ignore`, creds via field-scoped KV lookup, and **`ansible_become: false`** (the global sudo `become` is invalid on Windows — the exec wrapper needs `runas`; win_* tasks run as the admin and need no escalation).

### Playbooks
- `site.yml`: a **pre-flight** play (assert the vault URL + secret name are set and that the inventory discovered hosts), then a **Linux play** and a **Windows play** (each applies the `baseline` role and installs a baseline package), with `serial` for rolling batches and `max_fail_percentage` for blast-radius control.
- **Packages come from public/default sources** — the distro's built-in `apt`/`dnf` repos and Chocolatey's public community feed over NAT egress. **Do not** wire an internal mirror; there is no `repo_base_url` indirection.
- Distro-specific playbooks default `hosts` to the **matching distro group** (`distro_ubuntu` / `distro_rhel`), not all of `os_linux`, and keep a `meta: end_host` guard on the wrong OS family.
- MySQL playbooks install **MariaDB from the distro repos** (no external vendor repo) and set the root password idempotently with `plugin: mysql_native_password` + `check_implicit_admin: true`.
- Windows playbooks (`microsoft.ad`, `ansible.windows`, `chocolatey.chocolatey`) mirror the AWS repo: forest promotion (`windows-adds`, role `dc`), domain join, IIS, Python (public choco feed), SMB share (parameterized principal, default `Authenticated Users` — not `Everyone`), and the ZMS enforcer (nonce from the `provision_key` secret field).
- `bootstrap.yml`: assert the secret name is present, install collections via the `ansible-galaxy` CLI (don't depend on a collection to install collections), and **write the SSH private key** from the KV secret to a key file **owned by and readable by the service user** (not root-only, since the timers run as that user).

### Reconverge & scheduling
- `scripts/reconverge.sh`: **source `/etc/ansible/estate.env` if present** (so manual runs work, not just the systemd unit), then `git pull --ff-only`, refresh collections, run `bootstrap.yml`.
- `scripts/notify-result.sh`: log each run's result to `/var/log/ansible/converge-status.log`, failures to `converge-failures.log`; optional alert to an **Azure Monitor action group / Event Grid** (derive the region/resource from env — no hardcoded region).
- `systemd` timers: a ~30-minute **bootstrap** timer (self-converge) and a ~60-minute **estate** timer (`site.yml`), each loading `EnvironmentFile=/etc/ansible/estate.env` and running as the service user; `ExecStopPost` calls `notify-result.sh`.

## Incorporate these specific decisions (carried over from the AWS lab)

1. **Random 5–7 char suffix** appended to every resource name; length variable-controlled and validated.
2. **Local backend**; no remote state.
3. **Outputs** include public and private IPs for all hosts, subnet IDs, zones, the private DNS zone id, the Key Vault URI, and the control-node identity — plus write a **`connection-details.txt`** (gitignored) via a `local_file` + template with, per instance: Name, ID, Subnet, Private IP, Public IP; the Linux SSH command; and the Windows RDP details.
4. **Proper route tables / NAT** for deterministic outbound; **no circular dependencies** (naming module is resourceless locals).
5. **One consolidated Key Vault secret** (8 keys above); **secret name injected at build time** into the control node via `custom_data` (Managed Identity means no credentials cross the boundary).
6. **Single management subnet** for the control node.
7. **Minimum 2 servers per OS**, role-list driven; first Windows `dc` gets `Domain_Controller=Enabled`; Linux/Windows role values become `Role` tags and `role_<value>` inventory groups.
8. **WinRM enabled** on Windows at first boot (self-signed 5986 listener).
9. **Distro-based grouping** via `distro_*` groups with `ansible_group_priority` (drives package manager and, if ever needed, login user).
10. **Field-scoped secret lookups** — no global bundle variable; `no_log` on sensitive tasks.
11. **`ansible_become: false`** for the Windows group.
12. **Public/default package sources** only (apt/dnf + public Chocolatey); no internal mirror.
13. **SSH key file** written readable by the service account; **key `.pem` permissions repaired** cross-platform via `terraform_data` (icacls/chmod).
14. **`reconverge.sh` sources `estate.env`**; cloud-init **creates `/var/log/ansible`** owned by the service user.
15. **`.gitattributes`** normalizes text to **LF** so scripts/YAML committed from Windows run correctly on the Linux control node.

## Variables (non-exhaustive, all with descriptions + defaults)
`name_prefix`, `environment`, `project`, `owner`, `cost_center`, `tags` (map), `random_suffix_length` (5–7), `location` (default `francecentral`), `vnet_cidr`, `availability_zones`, subnet prefixes (public/app/management/aks), `private_dns_zone_name`, `bastion_allowed_cidrs` (**no `0.0.0.0/0` default**), `bastion_vm_size`, `linux_vm_size`, `windows_vm_size`, `ansible_control_vm_size`, marketplace image refs per OS/distro, `ubuntu_server_roles` / `rhel_server_roles` / `windows_server_roles` (lists, min 2), `admin_username` (default `azureuser`), `windows_admin_username` + `windows_admin_password` (`sensitive`, no default), `control_repo_url`, `control_repo_branch`, `reconverge_minutes`, `populate_ansible_secret` (bool), `provision_key` (`sensitive`), `dsrm_password` / `domain_join_username` / `domain_join_password` / `mysql_root_password` (`sensitive`, default empty), `enable_customer_managed_disk_encryption` (bool), `artifact_storage_account` (optional).

## Outputs
VNet id; subnet ids; NAT Gateway + Public IP ids; route table ids; Private DNS zone id + record FQDNs; bastion public IP/FQDN; Linux & Windows VM ids and **private IPs**; control-node private IP + Managed Identity id; Key Vault **URI** + consolidated secret name; SSH key name + private key path (`sensitive`); `connection-details.txt` path.

## Deliverables
1. All Terraform files and modules above, `terraform fmt`-clean and `terraform validate`-passing.
2. `terraform.tfvars.example` with a complete working example.
3. The **Ansible `control-repo/`** (inventory, group_vars, roles, playbooks, scripts, systemd) as specified, `ansible-lint`/`yamllint`-clean.
4. `README.md` documenting inputs, outputs, the naming/tagging scheme, how to SSH through the bastion to the Linux hosts and RDP to Windows, the Ansible push workflow, and a **troubleshooting section** covering: empty inventory (wrong subscription/RG or missing `ManagedBy=Terraform` tag), Linux `UNREACHABLE`/publickey (login user / key perms), Windows `become`/WinRM, Key Vault `get` denied (Managed Identity role assignment), and the Windows SSH-key-permissions `icacls` one-liner.
5. A **high-level design diagram** (draw.io or equivalent) with light/pastel colours, plus separate tables for roles, subnets/routes, and NSGs.

## Constraints
- Terraform `>= 1.5`; providers pinned in `versions.tf`: `hashicorp/azurerm ~> 3.x` (or current), `hashicorp/azuread`, `hashicorp/tls`, `hashicorp/local`, `hashicorp/random`.
- No hardcoded subscription IDs, locations, or image versions where they can be resolved or parameterized.
- Deployable with only `terraform.tfvars` edits — no source changes to customise names, tags, sizes, counts, or CIDRs.
- The control node authenticates to Azure (inventory + Key Vault) **only via its Managed Identity** — no secrets or service-principal keys on disk.
```
