variable "name_prefix" {
  description = "Short organisation/stack prefix used as the first segment of every resource name (e.g. \"zms\")."
  type        = string
}

variable "environment" {
  description = "Deployment environment, second segment of every name (e.g. dev, staging, prod)."
  type        = string
}

variable "project" {
  description = "Project name, applied as the standard `Project` tag."
  type        = string
}

variable "owner" {
  description = "Owning team or individual, applied as the standard `Owner` tag."
  type        = string
}

variable "cost_center" {
  description = "Cost center identifier, applied as the standard `CostCenter` tag."
  type        = string
}

variable "tags" {
  description = "Arbitrary additional tags merged on top of the standard tag set and applied to every resource."
  type        = map(string)
  default     = {}
}
