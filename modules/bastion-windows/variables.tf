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
  description = "ID of the VPC the Windows bastion lives in."
  type        = string
}

variable "subnet_id" {
  description = "Public subnet ID to launch the Windows bastion into."
  type        = string
}

variable "ami_ssm_parameter" {
  description = "SSM public parameter path resolving to the Windows bastion AMI (default: Windows Server 2022)."
  type        = string
  default     = "/aws/service/ami-windows-latest/Windows_Server-2022-English-Full-Base"
}

variable "instance_type" {
  description = "Instance type for the Windows bastion."
  type        = string
  default     = "t3.medium"
}

variable "root_volume_size" {
  description = "Root EBS volume size in GiB."
  type        = number
  default     = 40
}

variable "kms_key_id" {
  description = "KMS key ARN/ID for root volume encryption. Null uses the account default EBS key."
  type        = string
  default     = null
}

variable "iam_instance_profile" {
  description = "Name of the IAM instance profile to attach (grants SSM access)."
  type        = string
  default     = null
}

variable "admin_username" {
  description = "Local Windows administrator account to ensure on the bastion for RDP."
  type        = string
  sensitive   = true
}

variable "admin_password" {
  description = "Password for the local Windows administrator account (sensitive; supply via tfvars/env)."
  type        = string
  sensitive   = true
}

variable "bastion_allowed_cidrs" {
  description = "CIDRs permitted to RDP (3389) to the Windows bastion. 0.0.0.0/0 is allowed but exposes RDP to the internet; prefer a specific admin /32."
  type        = list(string)

  validation {
    condition     = length(var.bastion_allowed_cidrs) > 0
    error_message = "Provide at least one CIDR for bastion_allowed_cidrs."
  }
}

variable "associate_eip" {
  description = "Whether to allocate and attach a stable Elastic IP to the Windows bastion."
  type        = bool
  default     = true
}
