# Build Prompt — Modular, Secure AWS Infrastructure in Terraform

> Paste the section below into your coding agent (Claude, Cursor, etc.). It is written as a complete, self-contained specification.

---

## Role

You are a **senior DevOps / Platform engineer**. You write production-grade, idiomatic Terraform. You favor small reusable modules, explicit variables over hardcoded values, least-privilege IAM, and infrastructure that is auditable and repeatable. 

## Objective

Build a **highly modular, customizable, and secure** AWS infrastructure using Terraform. Every meaningful value must be driven by input variables with sensible, documented defaults. The codebase must support **custom naming** and **arbitrary multiple tags** applied consistently to every resource. Include a **platform-agnostic mechanism to deploy software and run custom scripts** on both Windows and Linux EC2 instances (Linux packages and Windows MSI files).

## Design principles (apply throughout)

1. **Modularity** — Compose the stack from independent, reusable modules. No module reaches into another's internals; pass values via inputs/outputs only.
2. **Variable-driven** — No magic strings or hardcoded CIDRs, AMIs, sizes, or counts. Everything configurable via `variables.tf` with types, descriptions, and defaults. Provide `terraform.tfvars.example`.
3. **Custom naming** — A single naming convention produces every resource name. Implement a naming scheme such as `{prefix}-{environment}-{component}-{suffix}` driven by variables (e.g., `name_prefix`, `environment`). Expose a reusable local/module so names are consistent and overridable.
4. **Consistent multi-tagging** — Accept a `tags` map variable (any number of arbitrary key/values). Merge global tags + per-resource tags and apply to **every** taggable resource, ideally via the provider `default_tags` block plus resource-level merges. Include standard tags (Environment, Owner, Project, ManagedBy=Terraform, CostCenter) as variables.
5. **Security first** — Private-by-default for all workloads (no public IPs). The **only** internet-facing SSH entry point is the bastion host, and its SSH (22) ingress is locked to an allowed-CIDR variable (default your admin IP, never `0.0.0.0/0`). Workload Linux instances accept SSH only from the bastion's security group; Windows instances accept RDP only from the bastion/VPC, not the internet. Encrypt EBS volumes (KMS), enforce IMDSv2, restrict security groups to least privilege, use VPC endpoints to keep SSM/EC2/S3 traffic off the public internet, mark the Windows password and generated private key as `sensitive`, and store no secrets in code.
6. **Clean state & versions** — Pin `required_version` and provider versions. Parameterize remote state backend (S3 + DynamoDB lock) but keep it overridable.

## Repository / module structure (produce this)

```
.
├── main.tf                 # root: wires modules together
├── variables.tf            # all root inputs
├── outputs.tf              # key outputs (VPC id, subnet ids, instance ids, zone id, endpoints)
├── providers.tf            # provider + default_tags
├── versions.tf             # required_version + required_providers
├── terraform.tfvars.example
├── README.md               # usage, inputs, outputs, deployment-tool guide
└── modules/
    ├── naming/             # produces standardized names + merged tags (locals)
    ├── network/            # VPC, IGW, NAT GWs, subnets, route tables, VPC endpoints
    ├── dns/                # Route 53 private hosted zone + records
    ├── keypair/            # generates an SSH key pair (TLS) + aws_key_pair, writes private key locally
    ├── bastion/            # Ubuntu bastion host in a public subnet (SSH entry point)
    ├── compute-linux/      # Linux EC2 instances (Amazon Linux, Ubuntu), SSH key, IAM profile, SGs
    ├── compute-windows/    # Windows EC2 instances (2019, 2022), admin user/password, IAM profile, SGs
    └── deployment/         # SSM Distributor: instance role, packages, State Manager, Run Command
```

Each module must have its own `variables.tf`, `outputs.tf`, `main.tf`.

## Required infrastructure

### Networking (`modules/network`)
- **1 VPC** — CIDR from a variable (default e.g. `10.0.0.0/16`).
- **1 Internet Gateway**.
- **2 NAT Gateways** — one per AZ for high availability, each in a public subnet, with its own EIP.
- **2 Public subnets** — one per AZ (across 2 AZs), `map_public_ip_on_launch` controlled by variable, routed to the IGW. These also host the **bastion** and the NAT gateways.
- **2 Private subnets for EC2 instances** — one per AZ, routed to the AZ-local NAT GW.
- **2 Private subnets for EKS** — one per AZ, tagged appropriately for EKS (`kubernetes.io/role/internal-elb = 1`) for future cluster use; one NAT route per AZ.
- All subnet CIDRs derived from the VPC CIDR via `cidrsubnet()` and/or variables; AZs from a variable list or `data.aws_availability_zones`.
- Provide **VPC interface/gateway endpoints** for `ssm`, `ssmmessages`, `ec2messages`, and `s3` (gateway) so SSM works without internet egress and to satisfy the no-inbound-access security model.

### DNS (`modules/dns`)
- **Route 53 Private Hosted Zone** associated with the VPC, zone name from a variable (e.g. `internal.example.local`).
- Create **A records mapping every EC2 instance** (and a sensible naming scheme) to the private zone using each instance's private IP. Records must be generated dynamically so adding an instance auto-registers it.

### SSH key pair (`modules/keypair`)
- Generate a **new SSH key pair** with the `tls_private_key` resource (e.g. RSA 4096 or ED25519) and register the public key via `aws_key_pair`.
- Write the private key to a local file (e.g. `${path.root}/<name>.pem`, `0600`) and/or expose it as a `sensitive` output; optionally store it in SSM Parameter Store / Secrets Manager (variable-controlled). This single key pair is used to access **the bastion and all Linux hosts**.

### Bastion (`modules/bastion`)
- Deploy **1 × Ubuntu bastion host** in a **public subnet** with a public IP / EIP, using the generated SSH key pair.
- Instance type, AMI (Ubuntu 24.04 via SSM public parameter), and subnet variable-driven; encrypted root volume, IMDSv2 required, SSM instance profile attached.
- Security group: inbound **SSH (22) only from `bastion_allowed_cidrs`** (admin CIDR variable); egress to the VPC so it can reach private hosts. This is the single jump host into the private infrastructure.

### Linux compute (`modules/compute-linux`)
Deploy into the **private EC2 subnets**, no public IPs, IMDSv2 required, encrypted root volumes, SSM instance profile, using the **generated SSH key pair**:
- **1 × Amazon Linux** — instance type **t3.medium**.
- **1 × Ubuntu 24.04** — instance type **t3.medium**.
- Security group: inbound **SSH (22) only from the bastion's security group**; egress to VPC endpoints; **no public ingress**.
- Instance type, AMI (region-agnostic lookup), subnet placement, and volume size all variable-driven.

### Windows compute (`modules/compute-windows`)
Deploy into the **private EC2 subnets**, no public IPs, IMDSv2 required, encrypted root volumes, SSM instance profile:
- **1 × Windows Server 2019** (AMI via SSM public parameter, region-agnostic).
- **1 × Windows Server 2022** (same lookup pattern).
- **Admin credentials supplied by the user as variables** — `windows_admin_username` and `windows_admin_password` (both `sensitive`); set the local admin account via `user_data` (PowerShell/cloudbase-init) on first boot. Do not commit values; pass via `terraform.tfvars` or environment.
- Security group: inbound **RDP (3389) only from the bastion SG / VPC**, never the internet; egress to VPC endpoints.
- Instance type, AMI, subnet placement, and volume size all variable-driven (default reasonable, e.g. t3.medium/large).

### Software deployment (`modules/deployment`) — see evaluation below.

## Software deployment evaluation (do this analysis, then implement the recommendation)

**Requirement:** a single, flexible, *platform-agnostic* way to install/configure software and run custom scripts on both Windows (MSI) and Linux (deb/rpm) instances.

| Option | Cross-platform | Network model | Idempotent / desired-state | Native to AWS | Notes |
|---|---|---|---|---|---|
| `user_data` / cloud-init / cloudbase-init | Partial (different per OS) | n/a | No (runs once at boot) | Yes | Good only for first-boot bootstrap, not ongoing management. |
| **AWS Systems Manager (SSM)** | **Yes** | Outbound-only via SSM endpoints; no SSH/RDP, no bastion | Yes (State Manager) | **Yes** | Distributor packages MSI/deb/rpm; Run Command for ad-hoc; Session Manager for shell; fully IAM-audited. |
| Ansible | Yes | SSH (Linux) + WinRM (Windows) — needs open ports/creds | Yes | No | Most flexible config language; can run *over* SSM to avoid open ports. |
| Chef / Puppet / SaltStack | Yes | Agent + master | Yes | No | Heavier; extra infra to run a master. |
| Packer (golden AMIs) | Yes | Build-time only | Immutable | No | Best for baked images; not for runtime/day-2 changes. |

**Decision (implement this): AWS SSM Distributor is the software-deployment mechanism.**

Rationale: SSM is genuinely platform-agnostic and runs over the pre-installed SSM Agent (present on all four target AMIs) plus the VPC endpoints in the network module, so deployments need no extra open ports and are fully IAM-scoped and CloudTrail-audited. SSH/RDP via the bastion exists for **interactive human access**, while **all software install/config is done through SSM** — the two concerns stay separate. Concretely:

- **SSM Distributor (primary)** — package and version software, then distribute: **`.msi` to Windows**, **`.deb`/`.rpm` to Linux**. Define packages as variables so users add their own artifacts (stored in S3).
- **SSM State Manager Associations** — bind Distributor packages/scripts to instances **by tag** for **idempotent, desired-state** enforcement (re-applies on a schedule), so Linux packages land on Linux hosts and MSIs on Windows hosts automatically.
- **SSM Run Command** — `AWS-RunShellScript` (Linux) and `AWS-RunPowerShellScript` (Windows) for ad-hoc custom scripts.

`user_data` is used **only** for minimal first-boot bootstrap (confirm SSM Agent running, join private DNS, set the Windows local admin account); Packer is mentioned in the README as the path for teams that prefer immutable golden images.

Implement in `modules/deployment`:
- An IAM role + instance profile with `AmazonSSMManagedInstanceCore` (least privilege; add S3 read for the artifact bucket only).
- A variable-driven list of Distributor packages and State Manager associations, **targeted by tag**, so Linux packages land on Linux hosts and MSIs on Windows hosts automatically.
- Example association(s) showing one Linux package install and one Windows MSI install.

## Variables (non-exhaustive, all with descriptions + defaults)
`name_prefix`, `environment`, `tags` (map), `aws_region`, `vpc_cidr`, `availability_zones`, public/private/eks subnet CIDR lists, `private_dns_zone_name`, per-instance maps (ami/instance_type/volume size), `linux_instance_type` (default `t3.medium`), `enable_nat_gateway`, `ssm_packages` (list of objects), `artifact_bucket`, `bastion_instance_type`, `bastion_allowed_cidrs` (list, **no default to `0.0.0.0/0`**), `key_pair_name`, `windows_admin_username`, `windows_admin_password` (`sensitive`, no default).

## Outputs
VPC ID; public/private/EKS subnet IDs; NAT GW & EIP IDs; route table IDs; Route 53 zone ID + record FQDNs; bastion public IP/DNS; Linux & Windows instance IDs and private IPs; SSH key pair name + private key path (`sensitive`); instance profile ARN; VPC endpoint IDs.

## Deliverables
1. All Terraform files and modules above, `terraform fmt`-clean and `terraform validate`-passing.
2. `terraform.tfvars.example` with a complete working example.
3. `README.md` documenting inputs, outputs, the naming/tagging scheme, how to SSH through the bastion to the Linux hosts (with the generated key) and RDP to Windows (with the supplied credentials), and the SSM Distributor software-deployment workflow with copy-paste examples for adding a Linux package and a Windows MSI.

## Constraints
- Terraform `>= 1.5`, AWS provider `~> 5.0`, plus `hashicorp/tls` and `hashicorp/local` (for SSH key generation) pinned in `versions.tf`.
- No hardcoded account IDs, regions, or AMI IDs — resolve dynamically.
- Code must be deployable with only `terraform.tfvars` edits; no source changes required to customize names, tags, sizes, or CIDRs.
```
