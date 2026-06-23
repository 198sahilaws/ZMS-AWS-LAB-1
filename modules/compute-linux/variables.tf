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
  description = "Private EC2 subnet IDs. Instances are distributed across these by index."
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

variable "default_instance_type" {
  description = "Instance type used when an instance entry does not override it."
  type        = string
  default     = "t3.medium"
}

variable "default_root_volume_size" {
  description = "Root volume size in GiB used when an instance entry does not override it."
  type        = number
  default     = 30
}

variable "instances" {
  description = <<-EOT
    Map of logical name => Linux instance definition. Each instance becomes a
    private EC2 host plus a private-DNS A record. AMIs are resolved region-agnostically
    from SSM public parameters.
  EOT
  type = map(object({
    ami_ssm_parameter = string
    instance_type     = optional(string)
    root_volume_size  = optional(number)
    os                = optional(string, "linux")
    role              = optional(string)
  }))
  default = {
    amazon = {
      ami_ssm_parameter = "/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64"
      os                = "amazon-linux"
    }
    ubuntu = {
      ami_ssm_parameter = "/aws/service/canonical/ubuntu/server/24.04/stable/current/amd64/hvm/ebs-gp3/ami-id"
      os                = "ubuntu"
    }
  }
}
