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
  description = "ID of the VPC the bastion lives in."
  type        = string
}

variable "vpc_cidr" {
  description = "VPC CIDR; the bastion egresses to this range to reach private hosts."
  type        = string
}

variable "subnet_id" {
  description = "Public subnet ID to launch the bastion into."
  type        = string
}

variable "key_name" {
  description = "Name of the EC2 key pair used for SSH access."
  type        = string
}

variable "ami_ssm_parameter" {
  description = "SSM public parameter path resolving to the bastion AMI (default: Ubuntu 24.04 LTS)."
  type        = string
  default     = "/aws/service/canonical/ubuntu/server/24.04/stable/current/amd64/hvm/ebs-gp3/ami-id"
}

variable "instance_type" {
  description = "Instance type for the bastion."
  type        = string
  default     = "t3.micro"
}

variable "root_volume_size" {
  description = "Root EBS volume size in GiB."
  type        = number
  default     = 20
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

variable "bastion_allowed_cidrs" {
  description = "CIDRs permitted to SSH (22) to the bastion. Must never be 0.0.0.0/0."
  type        = list(string)

  validation {
    condition     = !contains(var.bastion_allowed_cidrs, "0.0.0.0/0")
    error_message = "bastion_allowed_cidrs must not contain 0.0.0.0/0; restrict SSH to known admin CIDRs."
  }
}

variable "associate_eip" {
  description = "Whether to allocate and attach a stable Elastic IP to the bastion."
  type        = bool
  default     = true
}
