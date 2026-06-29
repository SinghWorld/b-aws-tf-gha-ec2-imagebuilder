## ---------------------------------------------------------------------------
## INFRASTRUCTURE CONFIGURATION
## ---------------------------------------------------------------------------
## Defines the temporary EC2 environment Image Builder uses to actually run
## the build and test phases: instance type, network placement, IAM profile,
## logging bucket, and SNS notifications on completion.

resource "aws_imagebuilder_infrastructure_configuration" "this" {
  name                          = "${var.name_prefix}-infra-config"
  description                   = "Build/test environment for ${var.name_prefix}"
  instance_profile_name         = aws_iam_instance_profile.imagebuilder_profile.name
  instance_types                = var.instance_types
  subnet_id                     = var.subnet_id
  security_group_ids            = var.security_group_ids
  terminate_instance_on_failure = true

  logging {
    s3_logs {
      s3_bucket_name = aws_s3_bucket.imagebuilder_logs.bucket
      s3_key_prefix  = "image-builder-logs/${var.name_prefix}"
    }
  }

  sns_topic_arn = var.sns_topic_arn != "" ? var.sns_topic_arn : null

  tags = var.tags
}

## ---------------------------------------------------------------------------
## Logging bucket
## ---------------------------------------------------------------------------
## Every build/test run streams full logs here. Required for auditability —
## if a build fails or a security test fails, this is where you debug it.

resource "aws_s3_bucket" "imagebuilder_logs" {
  bucket = "${var.name_prefix}-imagebuilder-logs-${data.aws_caller_identity.current.account_id}"
  tags   = var.tags
}

resource "aws_s3_bucket_lifecycle_configuration" "imagebuilder_logs" {
  bucket = aws_s3_bucket.imagebuilder_logs.id

  rule {
    id     = "expire-old-logs"
    status = "Enabled"

    filter {}

    expiration {
      days = 180
    }
  }
}

resource "aws_s3_bucket_public_access_block" "imagebuilder_logs" {
  bucket                  = aws_s3_bucket.imagebuilder_logs.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# ---------------------------------------------------------------------------
# S3 bucket policy — allow EC2 Image Builder service to write logs here.
# ---------------------------------------------------------------------------
# The EC2InstanceProfileForImageBuilder AWS managed policy only grants
# s3:PutObject to buckets matching the prefix `imagebuilder-*`. Our bucket is
# named `golden-win2022-imagebuilder-logs-<account>`, so without this explicit
# policy the build instance role can write but the Image Builder service
# principal cannot — and component log streaming silently fails.
data "aws_iam_policy_document" "imagebuilder_logs" {
  statement {
    sid    = "AllowImageBuilderToWriteLogs"
    effect = "Allow"

    principals {
      type        = "Service"
      identifiers = ["imagebuilder.amazonaws.com"]
    }

    actions = [
      "s3:PutObject",
      "s3:PutObjectAcl",
      "s3:GetObject",
      "s3:ListBucket",
    ]

    resources = [
      aws_s3_bucket.imagebuilder_logs.arn,
      "${aws_s3_bucket.imagebuilder_logs.arn}/*",
    ]

    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [data.aws_caller_identity.current.account_id]
    }
  }
}

resource "aws_s3_bucket_policy" "imagebuilder_logs" {
  bucket = aws_s3_bucket.imagebuilder_logs.id
  policy = data.aws_iam_policy_document.imagebuilder_logs.json

  depends_on = [aws_s3_bucket_public_access_block.imagebuilder_logs]
}

data "aws_caller_identity" "current" {}
