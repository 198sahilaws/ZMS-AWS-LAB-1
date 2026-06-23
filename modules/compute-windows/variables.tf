variable "name_prefix" {
  description = "Base name (\"{prefix}-{environment}\") used to compose resource names."
  type        = string
}

variable "suffix" {
  description = "Random alphanumeric suffix appended to the end of every resource name in this module."
  type        = string
  default     = ""
}

variable "tags" {
  description = "Tags applied to every resource in this module."
  type        = map(string)
  default     = {}
}

variable "vpc_id" {
  description = "ID of the VPC."
  type        = string
}

variable "vpc_cidr" {
  description = "VPC CIDR; RDP is allowed from this range / the bastion only, never the internet."
  type        = string
}

variable "subnet_ids" {
  description = "Private EC2 subnet IDs, one per AZ. Servers are round-robined across these (i.e. across AZs)."
  type        = list(string)
}

variable "iam_instance_profile" {
  description = "IAM instance profile name granting SSM access."
  type        = string
  default     = null
}

variable "bastion_security_group_id" {
  description = "Bastion SG ID; Windows instances accept RDP (3389) from this SG (in addition to the VPC range)."
  type        = string
}

variable "control_security_group_id" {
  description = "Ansible control-node SG ID. When set, Windows instances accept WinRM HTTPS (5986) from it (push). Null disables."
  type        = string
  default     = null
}

variable "kms_key_id" {
  description = "KMS key ARN/ID for root volume encryption. Null uses the account default EBS key."
  type        = string
  default     = null
}

variable "windows_admin_username" {
  description = "Local Windows administrator account name to ensure/create on first boot."
  type        = string
  sensitive   = true
}

variable "windows_admin_password" {
  description = "Password for the local Windows administrator account (set on first boot). No default; supply via tfvars or environment."
  type        = string
  sensitive   = true
}

variable "instance_type" {
  description = "Instance type for all Windows servers."
  type        = string
  default     = "t3.large"
}

variable "root_volume_size" {
  description = "Root volume size in GiB for Windows servers."
  type        = number
  default     = 50
}

variable "windows_server_count" {
  description = "Number of Windows servers to launch (round-robined across AZs)."
  type        = number
  default     = 1

  validation {
    condition     = var.windows_server_count >= 0
    error_message = "windows_server_count must be >= 0."
  }
}

variable "windows_ami_ssm_parameter" {
  description = "SSM public parameter resolving to the Windows AMI (default Windows Server 2022)."
  type        = string
  default     = "/aws/service/ami-windows-latest/Windows_Server-2022-English-Full-Base"
}
