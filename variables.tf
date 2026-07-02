#############################
# Naming & tagging
#############################

variable "name_prefix" {
  description = "Short organisation/stack prefix; first segment of every resource name (e.g. \"zms\")."
  type        = string
  default     = "zms"
}

variable "environment" {
  description = "Deployment environment; second segment of every name and the Environment tag (e.g. dev, staging, prod)."
  type        = string
  default     = "dev"
}

variable "project" {
  description = "Project name applied as the standard Project tag."
  type        = string
  default     = "zms-aws-lab"
}

variable "owner" {
  description = "Owning team/individual applied as the standard Owner tag."
  type        = string
  default     = "platform-team"
}

variable "cost_center" {
  description = "Cost center identifier applied as the standard CostCenter tag."
  type        = string
  default     = "engineering"
}

variable "tags" {
  description = "Arbitrary additional tags merged on top of the standard set and applied to every resource."
  type        = map(string)
  default     = {}
}

variable "random_suffix_length" {
  description = "Length of the random lowercase-alphanumeric suffix appended to every resource name (5-7)."
  type        = number
  default     = 6

  validation {
    condition     = var.random_suffix_length >= 5 && var.random_suffix_length <= 7
    error_message = "random_suffix_length must be between 5 and 7."
  }
}

#############################
# Provider / region
#############################

variable "aws_region" {
  description = "AWS region to deploy into."
  type        = string
  default     = "eu-west-3"
}

#############################
# Networking
#############################

variable "vpc_cidr" {
  description = "CIDR block for the VPC."
  type        = string
  default     = "10.0.0.0/16"
}

variable "availability_zones" {
  description = "Explicit AZ list. Empty selects the first two AZs in the region automatically."
  type        = list(string)
  default     = []
}

variable "public_subnet_cidrs" {
  description = "Optional explicit public subnet CIDRs (one per AZ). Empty derives them from vpc_cidr."
  type        = list(string)
  default     = []
}

variable "private_app_subnet_cidrs" {
  description = "Optional explicit private EC2 subnet CIDRs (one per AZ). Empty derives them from vpc_cidr."
  type        = list(string)
  default     = []
}

variable "private_eks_subnet_cidrs" {
  description = "Optional explicit private EKS subnet CIDRs (one per AZ). Empty derives them from vpc_cidr."
  type        = list(string)
  default     = []
}

variable "management_subnet_cidrs" {
  description = "Optional explicit management subnet CIDRs (one per AZ; hosts the Ansible control node). Empty derives them from vpc_cidr."
  type        = list(string)
  default     = []
}

variable "map_public_ip_on_launch" {
  description = "Whether public subnets auto-assign public IPs."
  type        = bool
  default     = true
}

variable "enable_nat_gateway" {
  description = "Whether to create NAT gateways and private default routes."
  type        = bool
  default     = true
}

variable "single_nat_gateway" {
  description = "Use a single shared NAT gateway instead of one per AZ (cheaper, less HA)."
  type        = bool
  default     = false
}

#############################
# DNS
#############################

variable "private_dns_zone_name" {
  description = "Route 53 private hosted zone name."
  type        = string
  default     = "internal.example.local"
}

variable "private_dns_force_destroy" {
  description = "Delete all records before destroying the private hosted zone (avoids HostedZoneNotEmpty on terraform destroy)."
  type        = bool
  default     = true
}

#############################
# SSH key pair
#############################

variable "key_pair_name" {
  description = "Name to register the generated SSH public key under. Empty uses \"{name_prefix}-{environment}-key-{suffix}\"."
  type        = string
  default     = ""
}

variable "store_private_key_in_ssm" {
  description = "Also store the generated private key in SSM Parameter Store (SecureString)."
  type        = bool
  default     = false
}

#############################
# Encryption
#############################

variable "create_kms_key" {
  description = "Create a dedicated KMS key for EBS encryption. When false, kms_key_id (or the account default EBS key) is used."
  type        = bool
  default     = true
}

variable "kms_key_id" {
  description = "Existing KMS key ARN/ID for EBS encryption when create_kms_key is false. Null uses the account default EBS key."
  type        = string
  default     = null
}

#############################
# Bastion
#############################

variable "bastion_instance_type" {
  description = "Instance type for the bastion host."
  type        = string
  default     = "t3.micro"
}

variable "bastion_allowed_cidrs" {
  description = "CIDRs permitted to SSH to the bastion. Set to your admin IP(s); 0.0.0.0/0 is permitted (e.g. roaming users) but exposes SSH to the whole internet."
  type        = list(string)
  # Intentionally no default: deployment fails until the operator sets this.

  validation {
    condition     = length(var.bastion_allowed_cidrs) > 0
    error_message = "Set bastion_allowed_cidrs to at least one CIDR (use a specific admin /32 where possible)."
  }
}

#############################
# Linux compute
#############################

variable "linux_instance_type" {
  description = "Instance type for all Linux servers (both Amazon Linux and Ubuntu)."
  type        = string
  default     = "t3.medium"
}

variable "amazon_linux_server_roles" {
  description = "One entry per Amazon Linux server (list length = count, min 2). Lowercase canonical role becomes the Role tag and the role_<value> Ansible group. Canonical values: dc, web, db, fileserver, client. e.g. [\"db\", \"web\"]."
  type        = list(string)
  default     = ["db", "web"]

  validation {
    condition     = length(var.amazon_linux_server_roles) >= 2
    error_message = "Provide at least 2 amazon_linux_server_roles (always deploy two or more)."
  }
}

variable "ubuntu_server_roles" {
  description = "One entry per Ubuntu server (list length = count, min 2). Lowercase canonical role -> Role tag / role_<value> group. e.g. [\"db\", \"web\"]."
  type        = list(string)
  default     = ["db", "web"]

  validation {
    condition     = length(var.ubuntu_server_roles) >= 2
    error_message = "Provide at least 2 ubuntu_server_roles (always deploy two or more)."
  }
}

variable "amazon_linux_ami_ssm_parameter" {
  description = "SSM public parameter resolving to the Amazon Linux AMI."
  type        = string
  default     = "/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64"
}

variable "ubuntu_ami_ssm_parameter" {
  description = "SSM public parameter resolving to the Ubuntu AMI."
  type        = string
  default     = "/aws/service/canonical/ubuntu/server/24.04/stable/current/amd64/hvm/ebs-gp3/ami-id"
}

#############################
# Windows compute
#############################

variable "windows_instance_type" {
  description = "Instance type for all Windows servers."
  type        = string
  default     = "t3.large"
}

variable "windows_server_roles" {
  description = "One entry per Windows server (list length = count, min 2). Lowercase canonical role -> Role tag / role_<value> group; a \"dc\" role also gets Domain_Controller=Enabled. Canonical values: dc, web, fileserver, client. e.g. [\"dc\", \"web\"]."
  type        = list(string)
  default     = ["dc", "web"]

  validation {
    condition     = length(var.windows_server_roles) >= 2
    error_message = "Provide at least 2 windows_server_roles (always deploy two or more)."
  }
}

variable "windows_ami_ssm_parameter" {
  description = "SSM public parameter resolving to the Windows AMI (default Windows Server 2022; switch to ...2019... for 2019)."
  type        = string
  default     = "/aws/service/ami-windows-latest/Windows_Server-2022-English-Full-Base"
}

variable "windows_admin_username" {
  description = "Local Windows administrator account name to ensure on first boot."
  type        = string
  sensitive   = true
  default     = "zmsadmin"
}

variable "windows_admin_password" {
  description = "Password for the local Windows administrator account. No default; supply via tfvars or TF_VAR_windows_admin_password."
  type        = string
  sensitive   = true
}

#############################
# Software management (Ansible — handled out-of-band)
#############################

variable "artifact_bucket" {
  description = "Optional S3 bucket of software artifacts (e.g. for Ansible to fetch deb/rpm/MSI). Empty disables the scoped S3 read policy on instances."
  type        = string
  default     = ""
}

#############################
# Ansible control node
#############################

variable "enable_ansible_control" {
  description = "Create the Ansible control node, its secrets, and the SG-to-SG push paths to managed hosts."
  type        = bool
  default     = true
}

variable "ansible_control_instance_type" {
  description = "Instance type for the Ansible control node."
  type        = string
  default     = "t3.medium"
}

variable "ansible_repo_volume_size" {
  description = "Size in GiB of the control node's persistent repo EBS volume (mounted at /srv/repos)."
  type        = number
  default     = 20
}

variable "control_repo_url" {
  description = "Git URL the control node clones for its Ansible push config. Empty skips the clone/reconverge automation."
  type        = string
  default     = "https://github.com/198sahilaws/ZMS-AWS-Ansible-2.git"
}

variable "control_repo_branch" {
  description = "Branch/checkout for ansible-pull."
  type        = string
  default     = "main"
}

variable "reconverge_minutes" {
  description = "ansible-pull reconverge interval in minutes (used only when control_repo_url is set)."
  type        = number
  default     = 15
}

variable "populate_ansible_secret" {
  description = "Populate the single consolidated Ansible credentials secret (SSH key + WinRM account) from Terraform. When false, only the empty container is created and the JSON value is set out of band."
  type        = bool
  default     = true
}

variable "provision_key" {
  description = "Arbitrary provisioning nonce (also the ZMS Enforcer nonce) stored in the consolidated secret under 'provision_key'. Override via tfvars / TF_VAR_provision_key for real values."
  type        = string
  sensitive   = true
  default     = "4|prod.zpath.net|1IcW2jdD3L1H6nk7FGniTJBzVm/gjIGk7GerjyW6NqQjhy2B7X+c//QG7GRqGZuIW6gfi7p7QIEHwHhCkEHc6YYfzoBWgbzKqpyWqEmLFvQew5EHM+ehID4UnwD02dJotI79PCG2YvsIX0xrnNP59WaEN3+et3R3uiMLSqBM8D7y5CDRiMTerVqAd9Yw5aYfVS8YW8Qdyie6xVPF2AtNhk2/wZxbxP8VJTo2C9dOvdblFwy/oF4Z2C6oDTf0RmF/seUOcKB60WhheLolEeK8gCJgtaicwXSkKpOdRjJj36f8oeWf0sw2IL2LCYW672Hw8wHs5DyJyWv5GaeIwO6ODOe+PaOBCHmq7cTzstpvKIDKA73y8P7RYWCIoUlnazWO|288263465653501953|1"
}

# Additional credentials folded into the single consolidated secret. All
# sensitive, all default to empty — set them in terraform.tfvars (or via
# TF_VAR_*) for the playbooks that need them.
variable "dsrm_password" {
  description = "AD DS DSRM / safe-mode password used by playbooks/windows-adds.yml (consolidated secret key 'dsrm_password')."
  type        = string
  sensitive   = true
  default     = ""
}

variable "domain_join_username" {
  description = "Domain-join account, e.g. ALCOR\\joinadmin (consolidated secret key 'domain_join_username')."
  type        = string
  sensitive   = true
  default     = ""
}

variable "domain_join_password" {
  description = "Password for the domain-join account (consolidated secret key 'domain_join_password')."
  type        = string
  sensitive   = true
  default     = ""
}

variable "mysql_root_password" {
  description = "MySQL root password used by the mysql playbooks (consolidated secret key 'mysql_root_password')."
  type        = string
  sensitive   = true
  default     = ""
}
