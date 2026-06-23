variable "name_prefix" {
  description = "Base name (\"{prefix}-{environment}\") used to compose resource names."
  type        = string
}

variable "suffix" {
  description = "Random alphanumeric suffix appended to the end of every resource name in this module."
  type        = string
  default     = ""
}

variable "key_name" {
  description = "Name to register the generated public key under in EC2. If empty, \"{name_prefix}-key-{suffix}\" is used."
  type        = string
  default     = ""
}

variable "tags" {
  description = "Tags applied to the key pair and any SSM parameter."
  type        = map(string)
  default     = {}
}

variable "algorithm" {
  description = "Key algorithm: RSA or ED25519."
  type        = string
  default     = "RSA"

  validation {
    condition     = contains(["RSA", "ED25519"], var.algorithm)
    error_message = "algorithm must be either RSA or ED25519."
  }
}

variable "rsa_bits" {
  description = "Key size in bits when algorithm is RSA."
  type        = number
  default     = 4096
}

variable "private_key_path" {
  description = "Directory in which to write the generated private key .pem file."
  type        = string
  default     = ""
}

variable "store_in_ssm" {
  description = "Also store the private key as a SecureString SSM parameter."
  type        = bool
  default     = false
}
