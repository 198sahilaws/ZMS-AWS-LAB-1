#############################
# Random stack suffix (appended to every resource name for uniqueness)
#############################

resource "random_string" "suffix" {
  length  = var.random_suffix_length
  lower   = true
  upper   = false
  numeric = true
  special = false
}

locals {
  # 5-7 char lowercase alphanumeric string, e.g. "a3f9k2". Appended to the end
  # of every resource name: {prefix}-{environment}-{component}-{suffix}.
  stack_suffix = random_string.suffix.result
}

#############################
# Naming + tags (single source of truth)
#############################

module "naming" {
  source = "./modules/naming"

  name_prefix = var.name_prefix
  environment = var.environment
  project     = var.project
  owner       = var.owner
  cost_center = var.cost_center
  tags        = var.tags
}

#############################
# Optional dedicated KMS key for EBS encryption
#############################

resource "aws_kms_key" "ebs" {
  count = var.create_kms_key ? 1 : 0

  description             = "${module.naming.base_name} EBS volume encryption"
  enable_key_rotation     = true
  deletion_window_in_days = 7

  tags = merge(module.naming.tags, { Name = "${module.naming.base_name}-ebs-kms-${local.stack_suffix}" })
}

resource "aws_kms_alias" "ebs" {
  count = var.create_kms_key ? 1 : 0

  name          = "alias/${module.naming.base_name}-ebs-${local.stack_suffix}"
  target_key_id = aws_kms_key.ebs[0].key_id
}

locals {
  ebs_kms_key_id = var.create_kms_key ? aws_kms_key.ebs[0].arn : var.kms_key_id

  # Control-node SG shared with the compute modules so managed hosts accept the
  # Ansible push paths. Null when the control node is disabled.
  control_security_group_id = one(module.ansible_control[*].security_group_id)

  # Private-DNS records for the control node (and a stable repo alias).
  ansible_dns_records = var.enable_ansible_control ? {
    "ansible-control" = module.ansible_control[0].private_ip
    "repo"            = module.ansible_control[0].private_ip
  } : {}
}

#############################
# Network
#############################

module "network" {
  source = "./modules/network"

  name_prefix              = module.naming.base_name
  suffix                   = local.stack_suffix
  tags                     = module.naming.tags
  aws_region               = var.aws_region
  vpc_cidr                 = var.vpc_cidr
  availability_zones       = var.availability_zones
  public_subnet_cidrs      = var.public_subnet_cidrs
  private_app_subnet_cidrs = var.private_app_subnet_cidrs
  private_eks_subnet_cidrs = var.private_eks_subnet_cidrs
  management_subnet_cidrs  = var.management_subnet_cidrs
  map_public_ip_on_launch  = var.map_public_ip_on_launch
  enable_nat_gateway       = var.enable_nat_gateway
  single_nat_gateway       = var.single_nat_gateway
}

#############################
# SSH key pair (bastion + all Linux hosts)
#############################

module "keypair" {
  source = "./modules/keypair"

  name_prefix  = module.naming.base_name
  suffix       = local.stack_suffix
  key_name     = var.key_pair_name
  tags         = module.naming.tags
  store_in_ssm = var.store_private_key_in_ssm
}

#############################
# Instance IAM profile (SSM core for keyless Session Manager access; software
# is managed out-of-band by Ansible)
#############################

module "deployment" {
  source = "./modules/deployment"

  name_prefix     = module.naming.base_name
  suffix          = local.stack_suffix
  tags            = module.naming.tags
  artifact_bucket = var.artifact_bucket
}

#############################
# Secrets (Ansible SSH private key + WinRM credential)
#############################

module "secrets" {
  source = "./modules/secrets"
  count  = var.enable_ansible_control ? 1 : 0

  name_prefix     = module.naming.base_name
  suffix          = local.stack_suffix
  tags            = module.naming.tags
  ssh_private_key = module.keypair.private_key_pem
  winrm_username  = var.windows_admin_username
  winrm_password  = var.windows_admin_password
  provision_key   = var.provision_key
  set_secret      = var.populate_ansible_secret
}

#############################
# Ansible control node (private; reached via bastion / Session Manager)
#############################

module "ansible_control" {
  source = "./modules/ansible-control"
  count  = var.enable_ansible_control ? 1 : 0

  # Secrets Manager containers (SSH key + WinRM credential) must exist before the
  # control node is built — Terraform injects their names into the node's user-data.
  depends_on = [module.secrets]

  name_prefix               = module.naming.base_name
  suffix                    = local.stack_suffix
  tags                      = module.naming.tags
  vpc_id                    = module.network.vpc_id
  vpc_cidr                  = module.network.vpc_cidr
  subnet_id                 = module.network.management_subnet_ids[0]
  bastion_security_group_id = module.bastion.security_group_id
  key_name                  = module.keypair.key_name
  instance_type             = var.ansible_control_instance_type
  repo_volume_size          = var.ansible_repo_volume_size
  kms_key_id                = local.ebs_kms_key_id
  aws_region                = var.aws_region
  secret_arn                = module.secrets[0].secret_arn
  secret_name               = module.secrets[0].secret_name
  control_repo_url          = var.control_repo_url
  control_repo_branch       = var.control_repo_branch
  reconverge_minutes        = var.reconverge_minutes
}

#############################
# Bastion (single SSH entry point)
#############################

module "bastion" {
  source = "./modules/bastion"

  name_prefix           = module.naming.base_name
  suffix                = local.stack_suffix
  tags                  = module.naming.tags
  vpc_id                = module.network.vpc_id
  vpc_cidr              = module.network.vpc_cidr
  subnet_id             = module.network.public_subnet_ids[0]
  key_name              = module.keypair.key_name
  instance_type         = var.bastion_instance_type
  bastion_allowed_cidrs = var.bastion_allowed_cidrs
  iam_instance_profile  = module.deployment.instance_profile_name
  kms_key_id            = local.ebs_kms_key_id
}

#############################
# Linux compute (private)
#############################

module "compute_linux" {
  source = "./modules/compute-linux"

  name_prefix               = module.naming.base_name
  suffix                    = local.stack_suffix
  tags                      = module.naming.tags
  vpc_id                    = module.network.vpc_id
  vpc_cidr                  = module.network.vpc_cidr
  subnet_ids                = module.network.private_app_subnet_ids
  key_name                  = module.keypair.key_name
  iam_instance_profile      = module.deployment.instance_profile_name
  bastion_security_group_id      = module.bastion.security_group_id
  control_security_group_id      = local.control_security_group_id
  kms_key_id                     = local.ebs_kms_key_id
  instance_type                  = var.linux_instance_type
  amazon_linux_server_count      = var.amazon_linux_server_count
  ubuntu_server_count            = var.ubuntu_server_count
  amazon_linux_ami_ssm_parameter = var.amazon_linux_ami_ssm_parameter
  ubuntu_ami_ssm_parameter       = var.ubuntu_ami_ssm_parameter
}

#############################
# Windows compute (private)
#############################

module "compute_windows" {
  source = "./modules/compute-windows"

  name_prefix               = module.naming.base_name
  suffix                    = local.stack_suffix
  tags                      = module.naming.tags
  vpc_id                    = module.network.vpc_id
  vpc_cidr                  = module.network.vpc_cidr
  subnet_ids                = module.network.private_app_subnet_ids
  iam_instance_profile      = module.deployment.instance_profile_name
  bastion_security_group_id = module.bastion.security_group_id
  control_security_group_id = local.control_security_group_id
  kms_key_id                = local.ebs_kms_key_id
  instance_type             = var.windows_instance_type
  windows_server_count      = var.windows_server_count
  windows_ami_ssm_parameter = var.windows_ami_ssm_parameter
  windows_admin_username    = var.windows_admin_username
  windows_admin_password    = var.windows_admin_password
}

#############################
# DNS (private zone + dynamic A records for every instance)
#############################

module "dns" {
  source = "./modules/dns"

  name_prefix   = module.naming.base_name
  suffix        = local.stack_suffix
  tags          = module.naming.tags
  vpc_id        = module.network.vpc_id
  zone_name     = var.private_dns_zone_name
  force_destroy = var.private_dns_force_destroy

  # Merge bastion + all Linux + all Windows hosts. Adding an instance to the
  # compute maps auto-registers a record here.
  instance_records = merge(
    { "bastion" = module.bastion.private_ip },
    module.compute_linux.dns_records,
    module.compute_windows.dns_records,
    local.ansible_dns_records,
  )
}
