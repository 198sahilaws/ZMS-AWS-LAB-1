output "base_name" {
  description = "The \"{prefix}-{environment}\" base name. Consumers append \"-{component}\" to build full resource names."
  value       = local.base_name
}

output "tags" {
  description = "Merged standard + custom tag map applied to every resource (also used as provider default_tags)."
  value       = local.tags
}
