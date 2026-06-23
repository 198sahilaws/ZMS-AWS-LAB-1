locals {
  sfx = var.suffix == "" ? "" : "-${var.suffix}"
}

# Private hosted zone associated with the VPC. Only resolvable from inside the VPC.
resource "aws_route53_zone" "private" {
  name = var.zone_name

  # When true, the provider deletes every record (except NS/SOA) before deleting
  # the zone, so `terraform destroy` never fails with HostedZoneNotEmpty — even
  # if records were added out of band.
  force_destroy = var.force_destroy

  vpc {
    vpc_id = var.vpc_id
  }

  tags = merge(var.tags, { Name = "${var.name_prefix}-private-zone${local.sfx}" })

  # Avoid churn if associations are managed elsewhere later.
  lifecycle {
    ignore_changes = [vpc]
  }
}

# Dynamically generated A records, one per instance. Driven entirely by the
# instance_records map so new instances register automatically.
resource "aws_route53_record" "instance" {
  for_each = var.instance_records

  zone_id = aws_route53_zone.private.zone_id
  name    = "${each.key}.${var.zone_name}"
  type    = "A"
  ttl     = var.record_ttl
  records = [each.value]
}
