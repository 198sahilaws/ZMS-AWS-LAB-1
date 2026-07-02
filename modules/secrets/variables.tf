variable "name_prefix" {
  description = "Base name (\"{prefix}-{environment}\") used to compose the secret name."
  type        = string
}

variable "suffix" {
  description = "Random alphanumeric suffix appended to the end of the secret name."
  type        = string
  default     = ""
}

variable "tags" {
  description = "Tags applied to the secret."
  type        = map(string)
  default     = {}
}

variable "ssh_private_key" {
  description = "Ansible SSH private key material stored under the ssh_private_key key of the consolidated secret."
  type        = string
  default     = ""
  sensitive   = true
}

variable "winrm_username" {
  description = "Windows account name Ansible uses over WinRM (winrm_username key of the consolidated secret)."
  type        = string
  default     = ""
  sensitive   = true
}

variable "winrm_password" {
  description = "Password for the WinRM account (winrm_password key of the consolidated secret)."
  type        = string
  default     = ""
  sensitive   = true
}

variable "provision_key" {
  description = "Arbitrary provisioning nonce (also used as the ZMS Enforcer nonce) stored under the provision_key key of the consolidated secret."
  type        = string
  default     = ""
  sensitive   = true
}

variable "dsrm_password" {
  description = "AD DS DSRM / safe-mode password (windows-adds) stored under dsrm_password."
  type        = string
  default     = ""
  sensitive   = true
}

variable "domain_join_username" {
  description = "Domain-join account (e.g. ALCOR\\joinadmin) stored under domain_join_username."
  type        = string
  default     = ""
  sensitive   = true
}

variable "domain_join_password" {
  description = "Domain-join account password stored under domain_join_password."
  type        = string
  default     = ""
  sensitive   = true
}

variable "mysql_root_password" {
  description = "MySQL root password (ubuntu/amazonlinux mysql playbooks) stored under mysql_root_password."
  type        = string
  default     = ""
  sensitive   = true
}

variable "set_secret" {
  description = "Populate the consolidated secret value from the inputs above. When false, only the empty container is created and the value is set out of band."
  type        = bool
  default     = true
}

variable "recovery_window_in_days" {
  description = "Secrets Manager recovery window on delete (0 allows immediate deletion, useful for labs)."
  type        = number
  default     = 7
}
