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
  description = "Arbitrary provisioning nonce stored under the provision_key key of the consolidated secret."
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
