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
  description = "VPC CIDR (informational / for any VPC-scoped rules)."
  type        = string
}

variable "subnet_id" {
  description = "Management (private) subnet ID to launch the control node into (no public IP)."
  type        = string
}

variable "bastion_security_group_id" {
  description = "Bastion SG ID; the control node accepts admin SSH only from the bastion."
  type        = string
}

variable "key_name" {
  description = "EC2 key pair name for admin SSH to the control node."
  type        = string
}

variable "ami_ssm_parameter" {
  description = "SSM public parameter resolving to the control-node AMI (default Ubuntu 24.04)."
  type        = string
  default     = "/aws/service/canonical/ubuntu/server/24.04/stable/current/amd64/hvm/ebs-gp3/ami-id"
}

variable "instance_type" {
  description = "Instance type for the control node."
  type        = string
  default     = "t3.medium"
}

variable "root_volume_size" {
  description = "Root EBS volume size in GiB."
  type        = number
  default     = 20
}

variable "repo_volume_size" {
  description = "Size in GiB of the persistent repo EBS volume mounted at /srv/repos."
  type        = number
  default     = 20
}

variable "kms_key_id" {
  description = "KMS key ARN/ID for EBS encryption. Null uses the account default EBS key."
  type        = string
  default     = null
}

variable "attach_secrets_policy" {
  description = "Attach the scoped secretsmanager:GetSecretValue policy for ssh_secret_arn/winrm_secret_arn. Plan-known flag (the ARNs themselves resolve at apply time). Set false for standalone use without secrets."
  type        = bool
  default     = true
}

variable "ssh_secret_arn" {
  description = "ARN of the SSH private-key secret the control node may read."
  type        = string
  default     = ""
}

variable "winrm_secret_arn" {
  description = "ARN of the WinRM credential secret the control node may read."
  type        = string
  default     = ""
}

variable "control_repo_url" {
  description = "Optional Git URL for ansible-pull. Empty skips the pull cron."
  type        = string
  default     = ""
}

variable "control_repo_branch" {
  description = "Branch/checkout for ansible-pull."
  type        = string
  default     = "main"
}

variable "reconverge_minutes" {
  description = "ansible-pull reconverge interval in minutes (when control_repo_url is set)."
  type        = number
  default     = 15
}
