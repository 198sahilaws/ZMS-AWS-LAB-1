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
  description = "VPC CIDR; instances egress to this range (and the VPC endpoints within it)."
  type        = string
}

variable "subnet_ids" {
  description = "Private EC2 subnet IDs, one per AZ. Servers are round-robined across these (i.e. across AZs)."
  type        = list(string)
}

variable "key_name" {
  description = "EC2 key pair name for SSH access (the generated key pair)."
  type        = string
}

variable "iam_instance_profile" {
  description = "IAM instance profile name granting SSM access."
  type        = string
  default     = null
}

variable "bastion_security_group_id" {
  description = "Bastion SG ID; Linux instances accept SSH (22) from this SG."
  type        = string
}

variable "control_security_group_id" {
  description = "Ansible control-node SG ID. When set, Linux instances also accept SSH (22) from it (push). Null disables."
  type        = string
  default     = null
}

variable "kms_key_id" {
  description = "KMS key ARN/ID for root volume encryption. Null uses the account default EBS key."
  type        = string
  default     = null
}

variable "instance_type" {
  description = "Instance type for all Linux servers (both Amazon Linux and Ubuntu)."
  type        = string
  default     = "t3.medium"
}

variable "root_volume_size" {
  description = "Root volume size in GiB for Linux servers."
  type        = number
  default     = 30
}

variable "amazon_linux_server_count" {
  description = "Number of Amazon Linux servers (minimum 2; round-robined across AZs). By ordinal: 1st=Database, 2nd=Web_Server, 3rd+=Client (Role tag)."
  type        = number
  default     = 2

  validation {
    condition     = var.amazon_linux_server_count >= 2
    error_message = "amazon_linux_server_count must be at least 2 (always deploy two or more)."
  }
}

variable "ubuntu_server_count" {
  description = "Number of Ubuntu servers (minimum 2; round-robined across AZs). By ordinal: 1st=Database, 2nd=Web_Server, 3rd+=Client (Role tag)."
  type        = number
  default     = 2

  validation {
    condition     = var.ubuntu_server_count >= 2
    error_message = "ubuntu_server_count must be at least 2 (always deploy two or more)."
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
