# ZMS AWS Lab — Modular, Secure Terraform Infrastructure

A highly modular, variable-driven AWS stack: a multi-AZ VPC with private-by-default
workloads, a single bastion SSH entry point, Linux and Windows EC2 instances, and a
Route 53 private zone. **Software is managed with Ansible** (out-of-band); the stack
provisions the infrastructure and keeps an SSM instance profile so hosts stay
reachable via Session Manager (keyless access, and Ansible-over-SSM if desired).

Everything meaningful is driven by input variables with documented defaults. The
stack is deployable with **only `terraform.tfvars` edits** — no source changes are
needed to customise names, tags, sizes, CIDRs, or instances.

---

## Architecture at a glance

```
                          Internet
                             │
                        ┌────┴────┐
                        │   IGW   │
                        └────┬────┘
        ┌────────────────────┼────────────────────┐
        │  Public subnet AZ-a │  Public subnet AZ-b │   (map_public_ip configurable)
        │   ┌──────────┐ NATa │        NATb         │
        │   │ Bastion  │      │                     │   SSH 22 ← admin CIDR only
        └───┴────┬─────┴──────┴──────────┬──────────┘
                 │ SSH                    │ SSH/RDP
   ┌─────────────┴───────────┐ ┌──────────┴──────────────┐
   │ Private app subnet AZ-a │ │ Private app subnet AZ-b │  no public IPs
   │  • Amazon Linux 2023    │ │  • Ubuntu 24.04         │  IMDSv2, encrypted EBS
   │  • Windows 2019         │ │  • Windows 2022         │
   └─────────────────────────┘ └─────────────────────────┘
   ┌─────────────────────────┐ ┌─────────────────────────┐
   │ Private EKS subnet AZ-a │ │ Private EKS subnet AZ-b │  tagged for future EKS
   └─────────────────────────┘ └─────────────────────────┘
   ┌─────────────────────────┐ ┌─────────────────────────┐
   │ Management subnet AZ-a  │ │ Management subnet AZ-b  │  Ansible control node
   │  • ansible-control      │ │                         │  (private, NAT egress)
   └─────────────────────────┘ └─────────────────────────┘

   VPC endpoints: ssm, ssmmessages, ec2messages, ec2 (interface) + s3 (gateway)
   Route 53 private zone: A record per instance (bastion, linux-*, win-*, ansible-control)
```

Module composition (no module reaches into another's internals — values flow only
through inputs/outputs):

```
root ── naming ──▶ base_name + merged tags (single source of truth)
     ├─ network ──▶ VPC, IGW, 2× NAT, public/app/eks/management subnets, route tables, VPC endpoints
     ├─ keypair ──▶ TLS key pair + aws_key_pair + local .pem (bastion + all Linux hosts)
     ├─ deployment ▶ instance IAM role/profile (SSM core for Session Manager access)
     ├─ secrets ──▶ Secrets Manager containers (Ansible SSH key, WinRM credential)
     ├─ ansible-control ▶ control node in the management subnet: SG, IAM (EC2 inventory + secrets + SSM), repo EBS
     ├─ bastion ──▶ Ubuntu jump host in a public subnet (only SSH ingress)
     ├─ compute-linux ▶ Amazon Linux + Ubuntu, private, SSH from bastion + control SGs
     ├─ compute-windows ▶ Windows 2019 + 2022, private, RDP from bastion + WinRM from control
     └─ dns ──────▶ private hosted zone + dynamic A records for every instance + control node
```

---

## Prerequisites

- Terraform `>= 1.5`
- AWS provider `~> 5.0`, plus `hashicorp/tls ~> 4.0` and `hashicorp/local ~> 2.4`
  (all pinned in `versions.tf`)
- AWS credentials with permission to create the resources above
- No hardcoded account IDs, regions, or AMI IDs — region is a variable and AMIs are
  resolved at plan time from SSM public parameters.

---

## Quick start

```bash
cp terraform.tfvars.example terraform.tfvars
# Edit terraform.tfvars — at minimum set:
#   bastion_allowed_cidrs = ["YOUR.ADMIN.IP/32"]   # never 0.0.0.0/0 (enforced)
#   windows_admin_password = "..."                  # or export TF_VAR_windows_admin_password

terraform init
terraform plan
terraform apply
```

### State backend

State is stored on the **local filesystem** (`backend "local"` in `versions.tf`,
path `terraform.tfstate`). No external bucket or lock table is required — just run
`terraform init` in the repo directory. To relocate the state file, override the
path at init: `terraform init -backend-config="path=/some/where/terraform.tfstate"`.

---

## Naming & tagging scheme

The `naming` module is the single source of truth. It produces:

- **`base_name`** = `lower("{name_prefix}-{environment}")`, e.g. `zms-dev`. Every
  module appends `-{component}-{suffix}`, yielding the
  **`{prefix}-{environment}-{component}-{suffix}`** convention.
- A **random lowercase-alphanumeric suffix** (length `random_suffix_length`, 5-7,
  default 6) is generated once by a `random_string` resource at the root and
  **appended to the end of every resource name** for stack uniqueness, e.g.
  `zms-dev-vpc-a3f9k2`, `zms-dev-bastion-a3f9k2`, `zms-dev-linux-amazon-a3f9k2`,
  `zms-dev-windows-win2022-a3f9k2`. It is exposed as the `stack_suffix` output.
  (The Route 53 zone name and instance hostnames stay functional and are **not**
  suffixed; only resource names/Name tags are.)
- **`tags`** = `merge(standard_tags, var.tags)`. The standard set is
  `Environment`, `Owner`, `Project`, `ManagedBy = "Terraform"`, `CostCenter`,
  each driven by its own variable. Arbitrary `var.tags` (any number of
  key/values) are merged on top.

These tags are applied **two ways** for full coverage:

1. Provider **`default_tags`** (in `providers.tf`) — applied automatically to every
   taggable resource the provider manages.
2. Resource-level **`merge(var.tags, { Name = "..." })`** — adds the per-resource
   `Name` (and role/tier tags) on top.

To rename everything or retag the whole stack, change `name_prefix`, `environment`,
or `tags` in `terraform.tfvars` — nothing else.

---

## Security model

- **Private by default.** Workload Linux/Windows instances have no public IPs and
  live in private subnets.
- **Single SSH entry point.** Only the bastion is internet-facing, and its SSH (22)
  ingress is locked to `bastion_allowed_cidrs`. A variable validation **rejects
  `0.0.0.0/0`** and requires at least one CIDR.
- **Least-privilege workload SGs.** Linux instances accept SSH only from the
  bastion's security group; Windows instances accept RDP only from the bastion SG
  and the VPC range — never the internet.
- **Encryption.** All root EBS volumes are encrypted; a dedicated KMS key (with
  rotation) is created by default, or supply your own via `kms_key_id`.
- **IMDSv2 enforced** on every instance (`http_tokens = required`).
- **No public path for SSM.** Interface VPC endpoints (`ssm`, `ssmmessages`,
  `ec2messages`, `ec2`) plus the S3 gateway endpoint keep management traffic off the
  public internet.
- **No secrets in code.** The Windows password and generated private key are marked
  `sensitive`; the password has no default and is supplied via tfvars/env.

---

## Routing & outbound connectivity

- **Public subnets** use one shared route table with a `0.0.0.0/0` → **Internet
  Gateway** route (inbound/outbound for the bastion and NAT gateways).
- **Private subnets** (the EC2/app, EKS, and **management** tiers) each use a **per-AZ**
  route table with a `0.0.0.0/0` → **AZ-local NAT gateway** route, giving every private
  host — including the Ansible control node in the management subnet — outbound internet
  access (OS updates, package mirrors) with no inbound exposure. With
  `single_nat_gateway = true` all private route tables point at one shared NAT.
- The **S3 gateway endpoint** is added to the public and all private route tables, so
  S3 (and SSM artifact) traffic stays on the AWS network.

## Connecting to instances

### SSH to a Linux host through the bastion

The generated private key is written to `./<key_name>.pem` (path is a `sensitive`
output: `terraform output -raw private_key_path`). The same key works for the
bastion and all Linux hosts.

```bash
BASTION=$(terraform output -raw bastion_public_ip)
KEY=$(terraform output -raw private_key_path)
LINUX_IP=$(terraform output -json linux_private_ips | jq -r '.amazon')

# One-hop with ProxyJump (recommended)
ssh -i "$KEY" -o ProxyJump=ubuntu@"$BASTION" ec2-user@"$LINUX_IP"   # Amazon Linux
ssh -i "$KEY" -o ProxyJump=ubuntu@"$BASTION" ubuntu@"$LINUX_IP"     # Ubuntu
```

(Bastion login user is `ubuntu`; Amazon Linux login user is `ec2-user`, Ubuntu is
`ubuntu`.) You can also resolve hosts by their private DNS names from the bastion,
e.g. `linux-amazon.internal.example.local`.

### RDP to a Windows host

Windows instances are private, so tunnel RDP through the bastion (or use SSM
Session Manager port forwarding, which needs no open ports at all):

```bash
# Option A: SSH local port-forward via the bastion
WIN_IP=$(terraform output -json windows_private_ips | jq -r '.win2022')
ssh -i "$KEY" -L 3389:"$WIN_IP":3389 ubuntu@"$BASTION"
# then RDP to localhost:3389

# Option B: SSM Session Manager port forwarding (no bastion, no open ports)
WIN_ID=$(terraform output -json windows_instance_ids | jq -r '.win2022')
aws ssm start-session --target "$WIN_ID" \
  --document-name AWS-StartPortForwardingSession \
  --parameters '{"portNumber":["3389"],"localPortNumber":["3389"]}'
```

Log in with `windows_admin_username` / `windows_admin_password` (the local admin
account set on first boot via `user_data`).

---

## Software management — Ansible

Software install/config is handled **out-of-band by Ansible**, not by Terraform.
Terraform's job is to stand up the infrastructure and make hosts reachable; Ansible
owns day-2 package and configuration management. The two concerns stay separate:
the bastion provides **interactive human access**, and Ansible drives the hosts for
**software management**.

This stack provisions a dedicated **Ansible control node** plus everything a
push-based control flow needs (`enable_ansible_control`, default `true`):

- **Control node (`modules/ansible-control`).** An Ubuntu host in a dedicated
  **management** subnet (private, no public IP), IMDSv2, KMS-encrypted root, plus a persistent encrypted EBS
  "repo" volume at `/srv/repos`. `cloud-init` installs ansible-core and, if
  `control_repo_url` is set, schedules an `ansible-pull` reconverge. Reach it via the
  **bastion** (admin SSH) or **Session Manager** — it carries `AmazonSSMManagedInstanceCore`.
- **Dynamic inventory + secrets IAM.** A dedicated role grants `ec2:Describe*` (for the
  `amazon.aws.aws_ec2` inventory plugin) and `secretsmanager:GetSecretValue` scoped to
  exactly the two secret ARNs below — separate from the managed-hosts SSM profile.
- **Push paths (SG-to-SG).** Managed **Linux** hosts accept **SSH/22** from the control
  node's SG; managed **Windows** hosts accept **WinRM HTTPS/5986** from it, and their
  `user_data` stands up a WinRM HTTPS listener (self-signed cert) on first boot. These
  rules appear only while the control node exists.
- **Secrets (`modules/secrets`).** Secrets Manager containers for the Ansible SSH
  private key and the WinRM credential. The generated SSH private key is **mirrored**
  into its secret (`mirror_ssh_key_to_secret`, default true); the WinRM value is set
  **out of band** by default (`set_winrm_secret = false`).
- **Discovery tags.** Every instance carries `OS` (`linux`/`windows`), `Role`
  (per-instance, override via the `role` field), and `Environment` — the contract the
  dynamic inventory groups and `--limit` on.
- **Private DNS.** The control node registers `ansible-control.<zone>` and a stable
  `repo.<zone>` alias in the existing private hosted zone.
- **Optional artifact bucket.** Set `artifact_bucket` to grant instances scoped,
  read-only S3 access so playbooks can pull deb/rpm/MSI artifacts from S3.

Alternative: because the SSM endpoints/agent are present, you can run **Ansible over
SSM** (`amazon.aws.aws_ssm` connection plugin) and skip the open SSH/WinRM ports
entirely. Set `enable_ansible_control = false` to omit the node, secrets, and push rules.

### Bring-up order

1. `terraform apply` — creates the control node, secrets containers, IAM, and push rules.
   The SSH secret is populated from the generated key automatically.
2. Set the **WinRM** secret value out of band (it's an empty container by default):

   ```bash
   aws secretsmanager put-secret-value \
     --secret-id "$(terraform output -raw ansible_winrm_secret_arn)" \
     --secret-string '{"username":"zmsadmin","password":"<pw>"}'
   ```
3. On the control node, point your `aws_ec2` inventory at `tag:OS` / `tag:Role`, and
   fetch the SSH key / WinRM credential from Secrets Manager at run time.

---

## Inputs (root)

| Variable | Description | Default |
|---|---|---|
| `name_prefix` | First name segment | `zms` |
| `environment` | Env segment + `Environment` tag | `dev` |
| `project` / `owner` / `cost_center` | Standard tag values | `zms-aws-lab` / `platform-team` / `engineering` |
| `tags` | Arbitrary extra tags (map) | `{}` |
| `random_suffix_length` | Length of random name suffix (5-7) | `6` |
| `aws_region` | Region | `us-east-1` |
| `vpc_cidr` | VPC CIDR | `10.0.0.0/16` |
| `availability_zones` | Explicit AZs (empty = first 2) | `[]` |
| `public_subnet_cidrs` / `private_app_subnet_cidrs` / `private_eks_subnet_cidrs` / `management_subnet_cidrs` | Optional explicit CIDRs (empty = derived via `cidrsubnet`) | `[]` |
| `map_public_ip_on_launch` | Public subnet auto-IP | `true` |
| `enable_nat_gateway` | Create NAT GWs | `true` |
| `single_nat_gateway` | One shared NAT instead of per-AZ | `false` |
| `private_dns_zone_name` | Route 53 private zone | `internal.example.local` |
| `key_pair_name` | Key pair name (empty = `{base_name}-key`) | `""` |
| `store_private_key_in_ssm` | Mirror key to SSM SecureString | `false` |
| `create_kms_key` / `kms_key_id` | Dedicated EBS KMS key, or BYO | `true` / `null` |
| `bastion_instance_type` | Bastion size | `t3.micro` |
| `bastion_allowed_cidrs` | SSH source CIDRs (**required, no `0.0.0.0/0`**) | — |
| `linux_instance_type` | Default Linux size | `t3.medium` |
| `linux_instances` | Map of Linux instances | Amazon Linux 2023 + Ubuntu 24.04 |
| `windows_instance_type` | Default Windows size | `t3.large` |
| `windows_instances` | Map of Windows instances | Windows 2019 + 2022 |
| `windows_admin_username` | Local admin name (`sensitive`) | `zmsadmin` |
| `windows_admin_password` | Local admin password (`sensitive`, **required**) | — |
| `artifact_bucket` | Optional S3 artifact bucket for Ansible to fetch (scoped read) | `""` |
| `enable_ansible_control` | Create the control node, secrets, and push paths | `true` |
| `ansible_control_instance_type` | Control node size | `t3.medium` |
| `ansible_repo_volume_size` | Control node repo volume (GiB) | `20` |
| `control_repo_url` / `control_repo_branch` | Optional `ansible-pull` source | `""` / `main` |
| `reconverge_minutes` | `ansible-pull` interval (when repo URL set) | `15` |
| `mirror_ssh_key_to_secret` | Mirror generated SSH key into its secret | `true` |
| `set_winrm_secret` | Populate WinRM secret from admin creds (else out of band) | `false` |

## Outputs (root)

Networking: `vpc_id`, `vpc_cidr`, `availability_zones`, `public_subnet_ids`,
`public_subnet_cidrs`, `private_app_subnet_ids`, `private_app_subnet_cidrs`,
`private_eks_subnet_ids`, `private_eks_subnet_cidrs`, `management_subnet_ids`,
`management_subnet_cidrs`, `subnet_availability_zones`
(map subnet ID → AZ), `nat_gateway_ids`, `nat_eip_ids`, `public_route_table_id`,
`private_route_table_ids`, `vpc_endpoint_ids`.

DNS: `private_zone_id`, `private_record_fqdns`.

Hosts (public **and** private IPs for every host): `bastion_public_ip`,
`bastion_public_dns`, `bastion_private_ip`, `linux_instance_ids`,
`linux_private_ips`, `linux_public_ips`, `windows_instance_ids`,
`windows_private_ips`, `windows_public_ips`, plus the consolidated
`all_host_private_ips` and `all_host_public_ips` maps. (Linux/Windows workloads are
private, so their public-IP maps are empty — only the bastion has a public IP.)

Ansible control node: `ansible_control_private_ip`, `ansible_control_instance_id`,
`ansible_control_security_group_id`, `ansible_control_fqdn`, `ansible_ssh_secret_arn`,
`ansible_winrm_secret_arn`.

Other: `key_pair_name`, `private_key_path` (`sensitive`), `instance_profile_arn`,
`stack_suffix`.

---

## Customising without touching source

| Goal | Edit in `terraform.tfvars` |
|---|---|
| Rename everything | `name_prefix`, `environment` |
| Retag everything | `tags`, `owner`, `project`, `cost_center` |
| Change network size/layout | `vpc_cidr`, `*_subnet_cidrs`, `availability_zones` |
| Cheaper non-prod networking | `single_nat_gateway = true` |
| Add/resize Linux or Windows hosts | `linux_instances`, `windows_instances`, `*_instance_type` |
| Lock down / open SSH source | `bastion_allowed_cidrs` |
| Give Ansible artifact access | `artifact_bucket` (scoped S3 read on instances) |

---

## Notes on validation in restricted networks

`terraform fmt`/`validate` require downloading provider schemas from the Terraform
registry. In an air-gapped or registry-blocked environment, run them where the
registry (or a private provider mirror) is reachable, or configure a
`provider_installation { filesystem_mirror { ... } }` block in your CLI config. The
code is written to canonical `terraform fmt` style and passes structural validation
(syntax, cross-module references, required inputs, no duplicate definitions).
