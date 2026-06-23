# The naming module is the single source of truth for resource names and tags.
# It owns no AWS resources; it only computes values consumed by every other
# module so naming and tagging stay consistent and overridable from one place.

locals {
  # Base name segment: "{prefix}-{environment}". Consumers append
  # "-{component}-{suffix}" to produce the full "{prefix}-{environment}-{component}-{suffix}"
  # convention, e.g. "zms-dev-vpc" or "zms-dev-linux-amazon".
  base_name = lower("${var.name_prefix}-${var.environment}")

  # Standard tags every resource receives. Custom `var.tags` override these on
  # key collision via the merge() below.
  standard_tags = {
    Environment = var.environment
    Owner       = var.owner
    Project     = var.project
    ManagedBy   = "Terraform"
    CostCenter  = var.cost_center
  }

  tags = merge(local.standard_tags, var.tags)
}
