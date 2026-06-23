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

variable "artifact_bucket" {
  description = "Optional S3 bucket of software artifacts (e.g. for Ansible to fetch deb/rpm/MSI). Grants instances read-only access. Empty disables the S3 policy."
  type        = string
  default     = ""
}
