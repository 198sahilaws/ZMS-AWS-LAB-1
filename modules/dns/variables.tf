variable "name_prefix" {
  description = "Base name (\"{prefix}-{environment}\") used to compose resource names."
  type        = string
}

variable "suffix" {
  description = "Random alphanumeric suffix appended to the hosted-zone Name tag (the DNS zone name itself stays functional)."
  type        = string
  default     = ""
}

variable "tags" {
  description = "Tags applied to the hosted zone."
  type        = map(string)
  default     = {}
}

variable "vpc_id" {
  description = "ID of the VPC to associate the private hosted zone with."
  type        = string
}

variable "zone_name" {
  description = "Private DNS zone name (e.g. internal.example.local)."
  type        = string
  default     = "internal.example.local"
}

variable "instance_records" {
  description = "Map of hostname (label) => private IP. One A record is created per entry, so adding an instance auto-registers it."
  type        = map(string)
  default     = {}
}

variable "record_ttl" {
  description = "TTL in seconds for the generated A records."
  type        = number
  default     = 300
}
