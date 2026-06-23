provider "aws" {
  region = var.aws_region

  # Global tags applied to every taggable resource the provider manages.
  # Resource-level `merge(var.tags, { Name = ... })` calls add per-resource
  # names on top of these defaults.
  default_tags {
    tags = module.naming.tags
  }
}
