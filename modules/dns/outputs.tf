output "zone_id" {
  description = "ID of the private hosted zone."
  value       = aws_route53_zone.private.zone_id
}

output "zone_name" {
  description = "Name of the private hosted zone."
  value       = aws_route53_zone.private.name
}

output "name_servers" {
  description = "Name servers for the private hosted zone."
  value       = aws_route53_zone.private.name_servers
}

output "record_fqdns" {
  description = "Map of hostname => fully qualified domain name for every generated A record."
  value       = { for k, r in aws_route53_record.instance : k => r.fqdn }
}
