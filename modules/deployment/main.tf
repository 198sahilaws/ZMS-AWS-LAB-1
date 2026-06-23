data "aws_partition" "current" {}

locals {
  sfx = var.suffix == "" ? "" : "-${var.suffix}"
}

#############################
# Instance role + profile (least privilege)
#############################

data "aws_iam_policy_document" "assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "ssm" {
  name               = "${var.name_prefix}-ssm-instance-role${local.sfx}"
  assume_role_policy = data.aws_iam_policy_document.assume.json

  tags = merge(var.tags, { Name = "${var.name_prefix}-ssm-instance-role${local.sfx}" })
}

# Core SSM permissions for keyless access (Session Manager, Run Command). Software
# is managed by Ansible; this profile is kept so instances remain reachable via
# Session Manager without opening ports and can be driven by Ansible-over-SSM.
resource "aws_iam_role_policy_attachment" "ssm_core" {
  role       = aws_iam_role.ssm.name
  policy_arn = "arn:${data.aws_partition.current.partition}:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

# Read-only access scoped to the single artifact bucket (only when provided).
data "aws_iam_policy_document" "artifact_read" {
  count = var.artifact_bucket != "" ? 1 : 0

  statement {
    sid       = "ListArtifactBucket"
    actions   = ["s3:ListBucket", "s3:GetBucketLocation"]
    resources = ["arn:${data.aws_partition.current.partition}:s3:::${var.artifact_bucket}"]
  }

  statement {
    sid       = "ReadArtifacts"
    actions   = ["s3:GetObject"]
    resources = ["arn:${data.aws_partition.current.partition}:s3:::${var.artifact_bucket}/*"]
  }
}

resource "aws_iam_role_policy" "artifact_read" {
  count  = var.artifact_bucket != "" ? 1 : 0
  name   = "${var.name_prefix}-artifact-read${local.sfx}"
  role   = aws_iam_role.ssm.id
  policy = data.aws_iam_policy_document.artifact_read[0].json
}

resource "aws_iam_instance_profile" "ssm" {
  name = "${var.name_prefix}-ssm-instance-profile${local.sfx}"
  role = aws_iam_role.ssm.name

  tags = merge(var.tags, { Name = "${var.name_prefix}-ssm-instance-profile${local.sfx}" })
}
