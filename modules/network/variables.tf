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

variable "aws_region" {
  description = "AWS region, used to build VPC endpoint service names."
  type        = string
}

variable "vpc_cidr" {
  description = "CIDR block for the VPC."
  type        = string
  default     = "10.0.0.0/16"
}

variable "availability_zones" {
  description = "Explicit list of AZs to use. If empty, the first two AZs available in the region are selected automatically."
  type        = list(string)
  default     = []
}

variable "az_count" {
  description = "Number of AZs to span when availability_zones is not set explicitly."
  type        = number
  default     = 2
}

variable "public_subnet_cidrs" {
  description = "Optional explicit CIDRs for the public subnets (one per AZ). If empty, derived from vpc_cidr via cidrsubnet()."
  type        = list(string)
  default     = []
}

variable "private_app_subnet_cidrs" {
  description = "Optional explicit CIDRs for the private EC2 subnets (one per AZ). If empty, derived from vpc_cidr via cidrsubnet()."
  type        = list(string)
  default     = []
}

variable "private_eks_subnet_cidrs" {
  description = "Optional explicit CIDRs for the private EKS subnets (one per AZ). If empty, derived from vpc_cidr via cidrsubnet()."
  type        = list(string)
  default     = []
}

variable "management_subnet_cidrs" {
  description = "Optional explicit CIDRs for the private management subnets (one per AZ; hosts the Ansible control node). If empty, derived from vpc_cidr via cidrsubnet()."
  type        = list(string)
  default     = []
}

variable "map_public_ip_on_launch" {
  description = "Whether instances launched into the public subnets receive a public IP automatically."
  type        = bool
  default     = true
}

variable "enable_nat_gateway" {
  description = "Whether to create NAT gateways and the private->NAT default routes."
  type        = bool
  default     = true
}

variable "single_nat_gateway" {
  description = "When true, create a single shared NAT gateway instead of one per AZ (cost saving, lower availability)."
  type        = bool
  default     = false
}

variable "eks_subnet_tags" {
  description = "Extra tags applied only to the private EKS subnets (e.g. kubernetes.io/role/internal-elb)."
  type        = map(string)
  default = {
    "kubernetes.io/role/internal-elb" = "1"
  }
}

variable "interface_endpoints" {
  description = "List of AWS service short names to create interface VPC endpoints for (keeps SSM traffic off the internet)."
  type        = list(string)
  default     = ["ssm", "ssmmessages", "ec2messages", "ec2"]
}

variable "enable_s3_gateway_endpoint" {
  description = "Whether to create the S3 gateway VPC endpoint (used by SSM Distributor artifacts)."
  type        = bool
  default     = true
}
