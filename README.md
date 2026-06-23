# ZMS AWS Lab — Modular, Secure Terraform Infrastructure

A highly modular, variable-driven Terraform stack that builds a secure, multi-AZ
AWS estate: a VPC with public / application / EKS / **management** subnet tiers,
high-availability NAT, a single bastion SSH entry point, private Linux and Windows
workloads, a Route 53 private zone, KMS-encrypted storage, and a dedicated
**Ansible control node** for push-based software management.

Every meaningful value is driven by an input variable with a documented default.
The stack is deployable with **only `terraform.tfvars` edits** — no source changes
are needed to customise names, tags, sizes, CIDRs, instances, or the control plane.

---

## Table of contents

1. [Highlights](#highlights)
2. [Architecture](#architecture)
3. [Repository structure](#repository-structure)
4. [Module reference](#module-reference)
5. [Design principles](#design-principles)
6. [Prerequisites](#prerequisites)
7. [Quick start](#quick-start)
8. [State backend](#state-backend)
9. [Naming & tagging](#naming--tagging)
10. [Random stack suffix](#random-stack-suffix)
11. [Security model](#security-model)
12. [Networking](#networking)
13. [DNS](#dns)
14. [Key management](#key-management)
15. [Bastion](#bastion)
16. [Compute — Linux & Windows](#compute--linux--windows)
17. [Instance IAM / SSM](#instance-iam--ssm)
18. [Secrets](#secrets)
19. [Ansible control node & software management](#ansible-control-node--software-management)
20. [Connecting to instances](#connecting-to-instances)
21. [Root input variables](#root-input-variables)
22. [Root outputs](#root-outputs)
23. [Per-module inputs](#per-module-inputs)
24. [Customisation recipes](#customisation-recipes)
25. [Bring-up & apply order](#bring-up--apply-order)
26. [Tear-down](#tear-down)
27. [Validation & known limitations](#validation--known-limitations)
28. [Troubleshooting](#troubleshooting)

---

## Highlights

- **10 composable modules**, wired only through inputs/outputs — no module reaches
  into another's internals.
- **Four subnet tiers per AZ**: public, private application, private EKS (future
  use), and a dedicated **management** tier that hosts the Ansible control node.
- **Private by default**: workloads have no public IPs; the bastion is the only
  internet-facing SSH entry point, locked to an admin CIDR allow-list.
- **Defence in depth**: IMDSv2 enforced, KMS-encrypted EBS, least-privilege IAM,
  SG-to-SG rules, and SSM/EC2/S3 VPC endpoints keeping management traffic off the
  public internet.
- **Consistent naming & tagging** from a single source of truth, plus a random
  alphanumeric suffix appended to every resource name for global uniqueness.
- **Ansible-ready**: a private control node with EC2-inventory + Secrets Manager
  IAM, SG-to-SG SSH/WinRM push paths, a WinRM listener bootstrap on Windows, and a
  discovery tag contract (`OS` / `Role` / `Environment`).
- **Local state backend** — no S3/DynamoDB required to get started.

---

## Architecture

```
                          Internet
                             │
                        ┌────┴────┐
                        │   IGW   │
                        └────┬────┘
        ┌────────────────────┼────────────────────┐
        │  Public subnet AZ-a │  Public subnet AZ-b │   map_public_ip configurable
        │   ┌──────────┐ NATa │        NATb         │   SSH 22 ← admin CIDR only
        │   │ Bastion  │      │                     │
        └───┴────┬─────┴──────┴──────────┬──────────┘
                 │ SSH                    │ SSH / RDP
   ┌─────────────┴───────────┐ ┌──────────┴──────────────┐
   │ Private app subnet AZ-a │ │ Private app subnet AZ-b │  no public IPs
   │  Amazon Linux / Ubuntu  │ │  Amazon Linux / Ubuntu  │  IMDSv2, encrypted EBS
   │  Windows  ◀── round-robin server counts across AZs ──▶ │
   └─────────────────────────┘ └─────────────────────────┘
   ┌─────────────────────────┐ ┌─────────────────────────┐
   │ Private EKS subnet AZ-a │ │ Private EKS subnet AZ-b │  tagged for future EKS
   └─────────────────────────┘ └─────────────────────────┘
   ┌─────────────────────────┐ ┌─────────────────────────┐
   │ Management subnet AZ-a  │ │ Management subnet AZ-b  │  Ansible control node
   │  • ansible-control      │ │                         │  (private, NAT egress)
   └─────────────────────────┘ └─────────────────────────┘

   VPC endpoints: ssm, ssmmessages, ec2messages, ec2 (interface) + s3 (gateway)
   Route 53 private zone: A record per host (bastion, linux-*, win-*, ansible-control, repo)
```

Push paths created by the control node (SG-to-SG, only while it exists):

```
   ansible-control SG ──SSH/22────▶ Linux workloads SG
   ansible-control SG ──WinRM/5986▶ Windows workloads SG
   bastion SG ─────────SSH/22─────▶ ansible-control SG   (admin access)
```

Module composition (values flow only through inputs/outputs):

```
root ── naming ──▶ base_name + merged tags (single source of truth)
     ├─ network ──▶ VPC, IGW, 2× NAT, public/app/eks/management subnets, route tables, VPC endpoints
     ├─ keypair ──▶ TLS key pair + aws_key_pair + local .pem (bastion + all Linux hosts)
     ├─ deployment ▶ instance IAM role/profile (SSM core for Session Manager access)
     ├─ secrets ──▶ Secrets Manager containers (Ansible SSH key, WinRM credential)
     ├─ ansible-control ▶ control node in the management subnet: SG, IAM, repo EBS
     ├─ bastion ──▶ Ubuntu jump host in a public subnet (only SSH ingress)
     ├─ compute-linux ▶ Amazon Linux + Ubuntu, private, SSH from bastion + control SGs
     ├─ compute-windows ▶ Windows 2019 + 2022, private, RDP from bastion + WinRM from control
     └─ dns ──────▶ private hosted zone + dynamic A records for every host
```

---

## Repository structure

```
.
├── main.tf                 # root: wires modules together, KMS key, random suffix
├── variables.tf            # all root inputs
├── outputs.tf              # key outputs (network, DNS, hosts, secrets, control node)
├── providers.tf            # AWS provider + default_tags
├── versions.tf             # required_version, providers, local backend
├── terraform.tfvars.example
├── .gitignore
├── README.md
└── modules/
    ├── naming/             # standardised names + merged tags (locals only, no resources)
    ├── network/            # VPC, IGW, NAT GWs, 4 subnet tiers, route tables, VPC endpoints
    ├── dns/                # Route 53 private hosted zone + dynamic A records
    ├── keypair/            # TLS key pair + aws_key_pair + local .pem (+ optional SSM)
    ├── deployment/         # instance IAM role/profile (SSM core + optional S3 read)
    ├── secrets/            # Secrets Manager containers (SSH key, WinRM credential)
    ├── ansible-control/    # private Ansible control node + cloud-init.yaml
    ├── bastion/            # Ubuntu bastion (single SSH entry point)
    ├── compute-linux/      # Amazon Linux + Ubuntu workloads
    └── compute-windows/    # Windows Server 2019 + 2022 workloads
```

---

## Module reference

| Module | Purpose | Key resources |
|---|---|---|
| `naming` | Single source of truth for names + merged tags. No AWS resources. | locals only (`base_name`, `tags`) |
| `network` | VPC, internet gateway, per-AZ NAT, four subnet tiers, route tables, VPC endpoints. | `aws_vpc`, `aws_internet_gateway`, `aws_subnet` ×4 tiers, `aws_eip`/`aws_nat_gateway`, `aws_route_table`/`aws_route`, `aws_vpc_endpoint` (interface + s3), endpoint SG |
| `keypair` | Generates an SSH key pair; writes the private key locally; optional SSM mirror. | `tls_private_key`, `aws_key_pair`, `local_sensitive_file`, optional `aws_ssm_parameter` |
| `deployment` | IAM instance profile for managed hosts: SSM core (+ scoped S3 read). | `aws_iam_role`, `aws_iam_role_policy_attachment`, optional `aws_iam_role_policy`, `aws_iam_instance_profile` |
| `secrets` | Secrets Manager containers for the Ansible SSH key and WinRM credential. | `aws_secretsmanager_secret` ×2, optional `aws_secretsmanager_secret_version` ×2 |
| `ansible-control` | Private control node + IAM (EC2 inventory + secrets read + SSM core) + repo EBS. | `aws_security_group`, `aws_iam_role`/policies/profile, `aws_instance`, `aws_ebs_volume` + attachment |
| `bastion` | Ubuntu jump host in a public subnet; the only public SSH ingress. | `aws_security_group`, `aws_instance`, `aws_eip` |
| `compute-linux` | Amazon Linux 2023 + Ubuntu 24.04 workloads, private. | `aws_security_group`, `aws_instance` (for_each) |
| `compute-windows` | Windows Server 2019 + 2022 workloads, private, WinRM listener. | `aws_security_group`, `aws_instance` (for_each) |
| `dns` | Route 53 private hosted zone + one A record per host. | `aws_route53_zone`, `aws_route53_record` (for_each) |

---

## Design principles

1. **Modularity** — every concern is an independent module; composition happens
   only at the root via explicit inputs/outputs.
2. **Variable-driven** — no magic strings. CIDRs derive from `vpc_cidr` via
   `cidrsubnet()`; AMIs resolve at plan time from SSM public parameters (region- and
   account-agnostic); sizes, counts, and names are all variables.
3. **Custom naming** — one convention, `{prefix}-{environment}-{component}-{suffix}`,
   produced centrally and overridable from one place.
4. **Consistent multi-tagging** — a standard tag set plus arbitrary user tags, applied
   both via the provider `default_tags` block and per-resource `Name`/role merges.
5. **Security first** — private by default, least-privilege IAM, IMDSv2, KMS
   encryption, SG-to-SG rules, VPC endpoints, secrets out of code/state.
6. **Clean versions & state** — pinned `required_version` and provider versions; a
   local backend that needs no external infrastructure.

---

## Prerequisites

- **Terraform** `>= 1.5`
- **Providers** (pinned in `versions.tf`): `hashicorp/aws ~> 5.0`,
  `hashicorp/tls ~> 4.0`, `hashicorp/local ~> 2.4`, `hashicorp/random ~> 3.6`
- **AWS credentials** with permission to create VPC, EC2, IAM, KMS, Route 53,
  Secrets Manager, and SSM resources
- No hardcoded account IDs, regions, or AMI IDs — the region is a variable and AMIs
  resolve from SSM public parameters.

---

## Quick start

```bash
cp terraform.tfvars.example terraform.tfvars

# Minimum edits required before apply:
#   bastion_allowed_cidrs  = ["YOUR.ADMIN.IP/32"]   # 0.0.0.0/0 allowed but discouraged
#   windows_admin_password = "..."                  # or export TF_VAR_windows_admin_password

terraform init
terraform plan
terraform apply
```

After apply, set the WinRM secret value out of band (see
[Ansible control node](#ansible-control-node--software-management)).

---

## State backend

State is stored on the **local filesystem** (`backend "local"` in `versions.tf`,
path `terraform.tfstate`). No bucket or lock table is required.

```bash
terraform init                                   # uses ./terraform.tfstate
terraform init -backend-config="path=/secure/loc/terraform.tfstate"   # relocate
```

Operational notes for local state:

- The state file contains resource metadata — including the generated **private
  key** and **secret ARNs** — in plaintext. Restrict its permissions, keep it out of
  Git (the provided `.gitignore` does this), and rely on full-disk encryption.
- There is **no locking** — never run `apply` from two places against the same state.
- Back it up. Losing it orphans the resources Terraform created.

---

## Naming & tagging

The `naming` module is the single source of truth. It produces:

- **`base_name`** = `lower("{name_prefix}-{environment}")`, e.g. `zms-dev`.
- **`tags`** = `merge(standard_tags, var.tags)` — the standard set is `Environment`,
  `Owner`, `Project`, `ManagedBy = "Terraform"`, `CostCenter`, each driven by its own
  variable; arbitrary user `tags` are merged on top.

Tags are applied **two ways** for full coverage:

1. Provider **`default_tags`** (in `providers.tf`) — applied automatically to every
   taggable resource.
2. Resource-level **`merge(var.tags, { Name = "..." })`** — adds per-resource `Name`,
   `Tier`, `OS`, `Role` tags.

To rename or retag the whole estate, change `name_prefix`, `environment`, or `tags`
in `terraform.tfvars` — nothing else.

---

## Random stack suffix

A `random_string` resource generates a lowercase-alphanumeric string of length
`random_suffix_length` (5–7, default 6, e.g. `a3f9k2`) and it is **appended to the
end of every resource name**, completing the `{prefix}-{environment}-{component}-{suffix}`
convention — `zms-dev-vpc-a3f9k2`, `zms-dev-ansible-control-a3f9k2`, etc. It is
exposed as the `stack_suffix` output. DNS zone names and instance hostnames stay
functional and are **not** suffixed (only resource names / `Name` tags are).

---

## Security model

- **Private by default.** Linux, Windows, and the Ansible control node have no public
  IPs and live in private subnets.
- **Single SSH entry point.** Only the bastion is internet-facing; its SSH ingress is
  locked to `bastion_allowed_cidrs`. A variable validation **requires at least one
  CIDR**; `0.0.0.0/0` is permitted (for roaming users) but exposes SSH to the internet,
  so a specific admin `/32` is strongly preferred.
- **Least-privilege SGs.** Linux accepts SSH only from the bastion and (when present)
  the control node SG. Windows accepts RDP from the bastion/VPC and WinRM only from the
  control node SG — never the internet.
- **Encryption.** All root and data EBS volumes are encrypted; a dedicated KMS key with
  rotation is created by default, or supply your own via `kms_key_id`.
- **IMDSv2 enforced** on every instance (`http_tokens = required`).
- **No public path for management.** Interface VPC endpoints (`ssm`, `ssmmessages`,
  `ec2messages`, `ec2`) plus the S3 gateway endpoint keep management traffic off the
  public internet; Session Manager works without open ports.
- **No secrets in code.** The Windows password and generated private key are
  `sensitive`; the password has no default; secret values live in Secrets Manager.

---

## Networking

### Subnet tiers

Four tiers, one subnet per AZ (two AZs by default). CIDRs derive from `vpc_cidr` via
`cidrsubnet(vpc_cidr, 8, offset)` unless overridden:

| Tier | Variable | Default offset | Example (`10.0.0.0/16`) | Public IP | Routing |
|---|---|---|---|---|---|
| Public | `public_subnet_cidrs` | `i` | `10.0.0.0/24`, `10.0.1.0/24` | configurable | IGW |
| Private app | `private_app_subnet_cidrs` | `i+10` | `10.0.10.0/24`, `10.0.11.0/24` | none | NAT |
| Private EKS | `private_eks_subnet_cidrs` | `i+20` | `10.0.20.0/24`, `10.0.21.0/24` | none | NAT |
| Management | `management_subnet_cidrs` | `i+30` | `10.0.30.0/24`, `10.0.31.0/24` | none | NAT |

The EKS subnets carry `kubernetes.io/role/internal-elb = 1` (and the public subnets
`kubernetes.io/role/elb = 1`) for future cluster use. The **management** subnet hosts
the Ansible control node.

### Routing & outbound connectivity

- **Public subnets** share one route table with `0.0.0.0/0` → **Internet Gateway**.
- **Private subnets** (app, EKS, and management) each use a **per-AZ** route table with
  `0.0.0.0/0` → **AZ-local NAT gateway**, giving every private host — including the
  control node — outbound access with no inbound exposure. With
  `single_nat_gateway = true`, all private route tables point at one shared NAT.
- The **S3 gateway endpoint** is attached to the public and all private route tables.

### NAT & endpoints

- **2 NAT gateways** (one per AZ) by default, each with its own EIP; toggle to a single
  shared NAT with `single_nat_gateway`, or disable with `enable_nat_gateway`.
- **Interface VPC endpoints** for `ssm`, `ssmmessages`, `ec2messages`, `ec2` (default
  `interface_endpoints`), guarded by an endpoint SG allowing 443 from the VPC CIDR, with
  private DNS enabled. **S3 gateway endpoint** controlled by `enable_s3_gateway_endpoint`.

---

## DNS

The `dns` module creates a **Route 53 private hosted zone** (`private_dns_zone_name`,
default `internal.example.local`) associated with the VPC, and one **A record per
host**, generated dynamically from a map so adding an instance auto-registers it.
Records include `bastion`, `linux-<name>`, `win-<name>`, `ansible-control`, and a
stable `repo` alias — e.g. `ansible-control.internal.example.local`.

---

## Key management

The `keypair` module generates an SSH key pair (`tls_private_key`, RSA 4096 by
default), registers the public key (`aws_key_pair`), and writes the private key to
`./<key_name>.pem` (mode `0600`). The same key authorises the bastion and all Linux
hosts. The private key is also exposed as a `sensitive` output and can be mirrored to
SSM (`store_private_key_in_ssm`) and/or to Secrets Manager (via the `secrets` module).

---

## Bastion

A single Ubuntu 24.04 jump host (`bastion_instance_type`, default `t3.micro`) in a
public subnet with an Elastic IP. SSH (22) ingress is restricted to
`bastion_allowed_cidrs`; egress is open so it can reach private hosts and package
mirrors. IMDSv2 enforced, root volume encrypted (KMS), SSM instance profile attached.
It is the jump host into the private estate (Linux SSH, Windows RDP, control-node SSH).

---

## Compute — Linux & Windows

Both compute modules launch into the private application subnets, with no public IPs,
IMDSv2 enforced, KMS-encrypted root volumes, and the SSM instance profile. AMIs resolve
from SSM public parameters.

### Server counts & round-robin AZ placement

The number of servers is controlled by **three count variables**, one per OS:

| Variable | OS | Default AMI | Default count |
|---|---|---|---|
| `amazon_linux_server_count` | Amazon Linux 2023 | `amazon_linux_ami_ssm_parameter` | `1` |
| `ubuntu_server_count` | Ubuntu 24.04 | `ubuntu_ami_ssm_parameter` | `1` |
| `windows_server_count` | Windows Server 2022 | `windows_ami_ssm_parameter` | `1` |

Each OS pool is distributed across the chosen availability zones using **round
robin**: server *i* of a pool lands in AZ `i % number_of_azs` (the private app
subnets are one-per-AZ). Pools are placed independently — each starts at the first
AZ. For example, with two AZs and `amazon_linux_server_count = 3`:

```
amazon-1 → AZ-a    amazon-2 → AZ-b    amazon-3 → AZ-a
```

Instances are named `…-linux-amazon-1`, `…-linux-ubuntu-2`, `…-windows-1`, etc.;
DNS records follow as `linux-amazon-1`, `win-1`, and so on. The number of AZs is set
by `availability_zones` / `az_count`.

**Linux SG** — SSH (22) from the bastion SG, and from the control node SG when present.

**Windows SG** — RDP (3389) from the bastion SG and VPC range; WinRM HTTPS (5986) from
the control node SG when present. First-boot `user_data` ensures the SSM agent, sets the
local admin account from `windows_admin_username`/`windows_admin_password`, and stands
up a WinRM HTTPS listener (self-signed cert).

Every instance carries the discovery tags **`OS`** (`linux`/`windows`), **`Role`**
(`amazon`/`ubuntu`/`windows`), and **`Environment`** (from the standard tag set).

---

## Instance IAM / SSM

The `deployment` module provisions the IAM role + instance profile attached to all
managed hosts. It grants `AmazonSSMManagedInstanceCore` (Session Manager, Run Command)
and, when `artifact_bucket` is set, a scoped read-only S3 policy for that bucket. This
keeps hosts reachable via Session Manager with no open ports, independent of Ansible.

---

## Secrets

The `secrets` module creates Secrets Manager **containers** for credentials so plaintext
never has to be authored in code:

- **SSH private key** (`<base>/ansible-ssh-private-key-<suffix>`) — populated by
  mirroring the generated key when `mirror_ssh_key_to_secret = true` (default).
- **WinRM credential** (`<base>/winrm-credential-<suffix>`) — an empty container by
  default (`set_winrm_secret = false`); set the value out of band, or flip the flag to
  populate it from `windows_admin_username`/`windows_admin_password`.

`recovery_window_in_days` (default 7) controls delete behaviour.

---

## Ansible control node & software management

Software install/config is handled **out of band by Ansible**, not by Terraform.
Terraform stands up the infrastructure and makes hosts reachable; Ansible owns day-2
package and configuration management. This stack provisions a dedicated control node
plus everything a push-based flow needs (`enable_ansible_control`, default `true`):

- **Control node (`modules/ansible-control`).** An Ubuntu host in the dedicated
  **management** subnet (private, no public IP), IMDSv2, KMS-encrypted root, plus a
  persistent encrypted EBS "repo" volume mounted at `/srv/repos`. `cloud-init` installs
  ansible-core and, if `control_repo_url` is set, schedules an `ansible-pull` reconverge
  every `reconverge_minutes`. Reach it via the bastion (admin SSH) or Session Manager
  (it carries `AmazonSSMManagedInstanceCore`).
- **Dynamic inventory + secrets IAM.** A dedicated role grants `ec2:Describe*` (for the
  `amazon.aws.aws_ec2` inventory plugin) and `secretsmanager:GetSecretValue` scoped to
  exactly the two secret ARNs — separate from the managed-hosts SSM profile.
- **Push paths (SG-to-SG).** Managed Linux hosts accept **SSH/22** from the control
  node SG; managed Windows hosts accept **WinRM HTTPS/5986** from it. These rules exist
  only while the control node exists.
- **Discovery tags.** `OS`, `Role`, and `Environment` on every instance form the contract
  the dynamic inventory groups and `--limit` on.
- **Private DNS.** The control node registers `ansible-control.<zone>` and a `repo.<zone>`
  alias in the private hosted zone.

> Alternative: because the SSM endpoints/agent are present, you can run **Ansible over
> SSM** (`amazon.aws.aws_ssm` connection plugin) and skip open SSH/WinRM ports entirely.
> Set `enable_ansible_control = false` to omit the node, secrets, and push rules.

### Bring-up order for Ansible

1. `terraform apply` — creates the control node, secrets containers, IAM, and push
   rules. The SSH secret is populated from the generated key automatically.
2. Set the **WinRM** secret value out of band (it is an empty container by default):

   ```bash
   aws secretsmanager put-secret-value \
     --secret-id "$(terraform output -raw ansible_winrm_secret_arn)" \
     --secret-string '{"username":"zmsadmin","password":"<pw>"}'
   ```

3. On the control node, point your `aws_ec2` inventory at `tag:OS` / `tag:Role`, and
   fetch the SSH key / WinRM credential from Secrets Manager at run time.

---

## Connecting to instances

The generated private key is at `./<key_name>.pem`
(`terraform output -raw private_key_path`); the same key works for the bastion and all
Linux hosts. Bastion login user is `ubuntu`; Amazon Linux is `ec2-user`; Ubuntu is
`ubuntu`.

**SSH to a Linux host via the bastion:**

```bash
BASTION=$(terraform output -raw bastion_public_ip)
KEY=$(terraform output -raw private_key_path)
LINUX_IP=$(terraform output -json linux_private_ips | jq -r '.amazon')

ssh -i "$KEY" -o ProxyJump=ubuntu@"$BASTION" ec2-user@"$LINUX_IP"   # Amazon Linux
ssh -i "$KEY" -o ProxyJump=ubuntu@"$BASTION" ubuntu@"$LINUX_IP"     # Ubuntu
```

**RDP to a Windows host** (tunnel through the bastion, or use Session Manager):

```bash
WIN_IP=$(terraform output -json windows_private_ips | jq -r '.win2022')
ssh -i "$KEY" -L 3389:"$WIN_IP":3389 ubuntu@"$BASTION"   # then RDP to localhost:3389

# Or Session Manager port-forwarding (no bastion, no open ports):
WIN_ID=$(terraform output -json windows_instance_ids | jq -r '.win2022')
aws ssm start-session --target "$WIN_ID" \
  --document-name AWS-StartPortForwardingSession \
  --parameters '{"portNumber":["3389"],"localPortNumber":["3389"]}'
```

**Reach the Ansible control node** (private) via the bastion or Session Manager:

```bash
CTRL_IP=$(terraform output -raw ansible_control_private_ip)
ssh -i "$KEY" -o ProxyJump=ubuntu@"$BASTION" ubuntu@"$CTRL_IP"

CTRL_ID=$(terraform output -raw ansible_control_instance_id)
aws ssm start-session --target "$CTRL_ID"
```

---

## Root input variables

### Naming & tagging

| Variable | Type | Default | Description |
|---|---|---|---|
| `name_prefix` | string | `zms` | First name segment. |
| `environment` | string | `dev` | Second segment + `Environment` tag. |
| `project` | string | `zms-aws-lab` | `Project` tag. |
| `owner` | string | `platform-team` | `Owner` tag. |
| `cost_center` | string | `engineering` | `CostCenter` tag. |
| `tags` | map(string) | `{}` | Arbitrary extra tags. |
| `random_suffix_length` | number | `6` | Random name suffix length (5–7). |

### Region & networking

| Variable | Type | Default | Description |
|---|---|---|---|
| `aws_region` | string | `us-east-1` | Region. |
| `vpc_cidr` | string | `10.0.0.0/16` | VPC CIDR. |
| `availability_zones` | list(string) | `[]` | Explicit AZs; empty = first two. |
| `public_subnet_cidrs` | list(string) | `[]` | Override public CIDRs. |
| `private_app_subnet_cidrs` | list(string) | `[]` | Override app CIDRs. |
| `private_eks_subnet_cidrs` | list(string) | `[]` | Override EKS CIDRs. |
| `management_subnet_cidrs` | list(string) | `[]` | Override management CIDRs. |
| `map_public_ip_on_launch` | bool | `true` | Public subnet auto-IP. |
| `enable_nat_gateway` | bool | `true` | Create NAT GWs + private routes. |
| `single_nat_gateway` | bool | `false` | One shared NAT instead of per-AZ. |

### DNS, keys, encryption

| Variable | Type | Default | Description |
|---|---|---|---|
| `private_dns_zone_name` | string | `internal.example.local` | Private hosted zone. |
| `key_pair_name` | string | `""` | Key pair name; empty = `{base}-key-{suffix}`. |
| `store_private_key_in_ssm` | bool | `false` | Mirror private key to SSM SecureString. |
| `create_kms_key` | bool | `true` | Create a dedicated EBS KMS key. |
| `kms_key_id` | string | `null` | BYO KMS key when `create_kms_key = false`. |

### Bastion & compute

| Variable | Type | Default | Description |
|---|---|---|---|
| `bastion_instance_type` | string | `t3.micro` | Bastion size. |
| `bastion_allowed_cidrs` | list(string) | — (**required**) | SSH source CIDRs (≥1); `0.0.0.0/0` allowed but discouraged. |
| `amazon_linux_server_count` | number | `1` | Number of Amazon Linux servers (round-robined across AZs). |
| `ubuntu_server_count` | number | `1` | Number of Ubuntu servers (round-robined across AZs). |
| `windows_server_count` | number | `1` | Number of Windows servers (round-robined across AZs). |
| `linux_instance_type` | string | `t3.medium` | Size for all Linux servers. |
| `windows_instance_type` | string | `t3.large` | Size for all Windows servers. |
| `amazon_linux_ami_ssm_parameter` | string | AL2023 SSM param | Amazon Linux AMI source. |
| `ubuntu_ami_ssm_parameter` | string | Ubuntu 24.04 SSM param | Ubuntu AMI source. |
| `windows_ami_ssm_parameter` | string | Windows 2022 SSM param | Windows AMI source. |
| `windows_admin_username` | string (sensitive) | `zmsadmin` | Local admin account. |
| `windows_admin_password` | string (sensitive) | — (**required**) | Local admin password. |

### Software management & Ansible control node

| Variable | Type | Default | Description |
|---|---|---|---|
| `artifact_bucket` | string | `""` | Optional S3 artifact bucket (scoped read). |
| `enable_ansible_control` | bool | `true` | Create control node, secrets, push paths. |
| `ansible_control_instance_type` | string | `t3.medium` | Control node size. |
| `ansible_repo_volume_size` | number | `20` | Repo EBS volume size (GiB). |
| `control_repo_url` | string | `""` | Optional `ansible-pull` Git URL. |
| `control_repo_branch` | string | `main` | `ansible-pull` branch. |
| `reconverge_minutes` | number | `15` | `ansible-pull` interval (when URL set). |
| `mirror_ssh_key_to_secret` | bool | `true` | Mirror generated SSH key into its secret. |
| `set_winrm_secret` | bool | `false` | Populate WinRM secret from admin creds. |

Server counts default to `1` per OS; set them to `0` to deploy none of that OS.
With `N` servers and `A` AZs, server `i` (0-indexed within its OS pool) is placed in
AZ `i % A`.

---

## Root outputs

**Networking** — `vpc_id`, `vpc_cidr`, `availability_zones`, `public_subnet_ids`,
`public_subnet_cidrs`, `private_app_subnet_ids`, `private_app_subnet_cidrs`,
`private_eks_subnet_ids`, `private_eks_subnet_cidrs`, `management_subnet_ids`,
`management_subnet_cidrs`, `subnet_availability_zones`, `nat_gateway_ids`,
`nat_eip_ids`, `public_route_table_id`, `private_route_table_ids`, `vpc_endpoint_ids`.

**DNS** — `private_zone_id`, `private_record_fqdns`.

**Hosts** (public **and** private IPs) — `bastion_public_ip`, `bastion_public_dns`,
`bastion_private_ip`, `linux_instance_ids`, `linux_private_ips`, `linux_public_ips`,
`windows_instance_ids`, `windows_private_ips`, `windows_public_ips`,
`all_host_private_ips`, `all_host_public_ips`. (Workloads are private, so their
public-IP maps are empty — only the bastion has a public IP.)

**Ansible control node** — `ansible_control_private_ip`, `ansible_control_instance_id`,
`ansible_control_security_group_id`, `ansible_control_fqdn`, `ansible_ssh_secret_arn`,
`ansible_winrm_secret_arn`.

**Other** — `key_pair_name`, `private_key_path` (`sensitive`), `instance_profile_arn`,
`stack_suffix`.

---

## Per-module inputs

A condensed view of each module's variables (root passes these via the wiring in
`main.tf`):

- **naming** — `name_prefix`, `environment`, `project`, `owner`, `cost_center`, `tags`.
- **network** — `name_prefix`, `suffix`, `tags`, `aws_region`, `vpc_cidr`,
  `availability_zones`, `az_count`, `public_subnet_cidrs`, `private_app_subnet_cidrs`,
  `private_eks_subnet_cidrs`, `management_subnet_cidrs`, `map_public_ip_on_launch`,
  `enable_nat_gateway`, `single_nat_gateway`, `eks_subnet_tags`, `interface_endpoints`,
  `enable_s3_gateway_endpoint`.
- **keypair** — `name_prefix`, `suffix`, `key_name`, `tags`, `algorithm`, `rsa_bits`,
  `private_key_path`, `store_in_ssm`.
- **deployment** — `name_prefix`, `suffix`, `tags`, `artifact_bucket`.
- **secrets** — `name_prefix`, `suffix`, `tags`, `ssh_private_key`, `set_ssh_secret`,
  `winrm_username`, `winrm_password`, `set_winrm_secret`, `recovery_window_in_days`.
- **ansible-control** — `name_prefix`, `suffix`, `tags`, `vpc_id`, `vpc_cidr`,
  `subnet_id`, `bastion_security_group_id`, `key_name`, `ami_ssm_parameter`,
  `instance_type`, `root_volume_size`, `repo_volume_size`, `kms_key_id`,
  `ssh_secret_arn`, `winrm_secret_arn`, `control_repo_url`, `control_repo_branch`,
  `reconverge_minutes`.
- **bastion** — `name_prefix`, `suffix`, `tags`, `vpc_id`, `vpc_cidr`, `subnet_id`,
  `key_name`, `ami_ssm_parameter`, `instance_type`, `root_volume_size`, `kms_key_id`,
  `iam_instance_profile`, `bastion_allowed_cidrs`, `associate_eip`.
- **compute-linux** — `name_prefix`, `suffix`, `tags`, `vpc_id`, `vpc_cidr`,
  `subnet_ids`, `key_name`, `iam_instance_profile`, `bastion_security_group_id`,
  `control_security_group_id`, `kms_key_id`, `instance_type`, `root_volume_size`,
  `amazon_linux_server_count`, `ubuntu_server_count`, `amazon_linux_ami_ssm_parameter`,
  `ubuntu_ami_ssm_parameter`.
- **compute-windows** — `name_prefix`, `suffix`, `tags`, `vpc_id`, `vpc_cidr`,
  `subnet_ids`, `iam_instance_profile`, `bastion_security_group_id`,
  `control_security_group_id`, `kms_key_id`, `instance_type`, `root_volume_size`,
  `windows_server_count`, `windows_ami_ssm_parameter`, `windows_admin_username`,
  `windows_admin_password`.
- **dns** — `name_prefix`, `suffix`, `tags`, `vpc_id`, `zone_name`, `instance_records`,
  `record_ttl`.

---

## Customisation recipes

| Goal | Edit in `terraform.tfvars` |
|---|---|
| Rename everything | `name_prefix`, `environment` |
| Retag everything | `tags`, `owner`, `project`, `cost_center` |
| Change network size/layout | `vpc_cidr`, `*_subnet_cidrs`, `availability_zones` |
| Cheaper non-prod networking | `single_nat_gateway = true` |
| Add/remove servers per OS | `amazon_linux_server_count`, `ubuntu_server_count`, `windows_server_count` |
| Resize servers / pick AMIs | `linux_instance_type`, `windows_instance_type`, `*_ami_ssm_parameter` |
| Spread servers over more AZs | `availability_zones` / `az_count` (round-robin follows automatically) |
| Tag a host with a role | add `role = "web"` to its `*_instances` entry |
| Lock down / open SSH source | `bastion_allowed_cidrs` |
| Disable the Ansible control node | `enable_ansible_control = false` |
| Auto-pull Ansible content | `control_repo_url`, `control_repo_branch`, `reconverge_minutes` |
| Give Ansible artifact access | `artifact_bucket` (scoped S3 read on instances) |

---

## Bring-up & apply order

1. `cp terraform.tfvars.example terraform.tfvars` and set `bastion_allowed_cidrs` +
   `windows_admin_password`.
2. `terraform init`
3. `terraform apply` — VPC, subnets (incl. management), NAT, endpoints, bastion,
   compute, IAM, KMS, key pair, secrets containers, Ansible control node, DNS.
4. Set the WinRM secret value out of band (`aws secretsmanager put-secret-value …`).
5. Configure Ansible on the control node (dynamic inventory on `tag:OS`/`tag:Role`;
   fetch credentials from Secrets Manager at run time).

---

## Tear-down

```bash
terraform destroy
```

Notes:

- Secrets Manager honours `recovery_window_in_days` (default 7) — secrets enter a
  recovery window rather than deleting immediately. Set it to `0` (in the `secrets`
  module input) for instant deletion in throwaway labs.
- The generated `*.pem` private key remains on disk (ignored by Git); remove it
  manually if no longer needed.
- Local state is not deleted by `destroy`; keep or archive `terraform.tfstate`.

---

## Validation & known limitations

- The code is written to canonical `terraform fmt` style and passes structural
  validation (HCL syntax, cross-module references, required inputs, no duplicate
  definitions, acyclic module graph).
- A full `terraform validate` requires downloading provider schemas from the Terraform
  registry. In an air-gapped or registry-blocked environment, run `init`/`validate`
  where the registry (or a private provider mirror via
  `provider_installation { filesystem_mirror { … } }`) is reachable.
- The module dependency graph is acyclic: `random_string` and `naming` feed `network`,
  `keypair`, and `deployment`; `keypair` → `secrets`; `network`/`bastion`/`secrets` →
  `ansible-control`; `ansible-control` → `compute-*`; everything → `dns`. The provider's
  `default_tags` references only the resourceless `naming` module, so there is no
  provider-on-resource dependency.

---

## Troubleshooting

| Symptom | Likely cause / fix |
|---|---|
| `apply` fails on `bastion_allowed_cidrs` | Required with ≥1 CIDR; set your admin `/32` (or `0.0.0.0/0` to allow any source). |
| `apply` fails on `windows_admin_password` | Required with no default; set it or export `TF_VAR_windows_admin_password`. |
| Can't reach a private host | Connect through the bastion (`ProxyJump`) or Session Manager; private hosts have no public IP by design. |
| WinRM auth fails from Ansible | Confirm the WinRM secret value was set out of band and the control node SG rule (5986) is present (`enable_ansible_control = true`). |
| Ansible inventory empty | Confirm the control node role has `ec2:Describe*` and instances carry `OS`/`Role` tags. |
| Two applies clobber state | Local backend has no locking — run Terraform from one place only. |
| `random_suffix_length` error | Must be between 5 and 7. |
```
