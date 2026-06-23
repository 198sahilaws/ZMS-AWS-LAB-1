variable "name_prefix" {
  description = "Base name (\"{prefix}-{environment}\") used to compose secret names."
  type        = string
}

variable "suffix" {
  description = "Random alphanumeric suffix appended to the end of every secret name in this module."
  type        = string
  default     = ""
}

variable "tags" {
  description = "Tags applied to every secret."
  type        = map(string)
  default     = {}
}

variable "ssh_private_key" {
  description = "Ansible SSH private key material to store in the SSH secret. Empty leaves the container value unset (set out of band)."
  type        = string
  default     = ""
  sensitive   = true
}

variable "set_ssh_secret" {
  description = "Whether to populate the SSH secret value from ssh_private_key. When false, only the empty container is created."
  type        = bool
  default     = true
}

variable "winrm_username" {
  description = "Windows account name Ansible uses over WinRM (only used when set_winrm_secret = true)."
  type        = string
  default     = ""
  sensitive   = true
}

variable "winrm_password" {
  description = "Password for the WinRM account (only used when set_winrm_secret = true)."
  type        = string
  default     = ""
  sensitive   = true
}

variable "set_winrm_secret" {
  description = "Whether to populate the WinRM secret with {username,password}. Default false: the container is created and the value is set out of band."
  type        = bool
  default     = false
}

variable "recovery_window_in_days" {
  description = "Secrets Manager recovery window on delete (0 allows immediate deletion, useful for labs)."
  type        = number
  default     = 7
}
