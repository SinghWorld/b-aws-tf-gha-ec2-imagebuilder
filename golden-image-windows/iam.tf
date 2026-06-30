## ---------------------------------------------------------------------------
## IAM role for the Image Builder build/test EC2 instance
## ---------------------------------------------------------------------------
## This is the role attached to the temporary instance Image Builder launches
## to run components and tests. It needs SSM (to receive commands) and the
## Image Builder managed policy (to report build status back).

data "aws_iam_policy_document" "imagebuilder_trust" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "imagebuilder_instance_role" {
  name               = "${var.name_prefix}-imagebuilder-role"
  assume_role_policy = data.aws_iam_policy_document.imagebuilder_trust.json
  tags               = var.tags
}

resource "aws_iam_role_policy_attachment" "ssm_managed_instance_core" {
  role       = aws_iam_role.imagebuilder_instance_role.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_role_policy_attachment" "imagebuilder_instance_policy" {
  role       = aws_iam_role.imagebuilder_instance_role.name
  policy_arn = "arn:aws:iam::aws:policy/EC2InstanceProfileForImageBuilder"
}

# Optional but recommended: allows the build instance to push detailed logs
resource "aws_iam_role_policy_attachment" "imagebuilder_ecr_logs" {
  role       = aws_iam_role.imagebuilder_instance_role.name
  policy_arn = "arn:aws:iam::aws:policy/EC2InstanceProfileForImageBuilderECRContainerBuilds"
}

# ---------------------------------------------------------------------------

# Inline policy: explicit S3 access to the logs bucket.
# ---------------------------------------------------------------------------
# The EC2InstanceProfileForImageBuilder managed policy only grants
# s3:PutObject to buckets whose name starts with `imagebuilder-*`. Our logs
# bucket is named `${var.name_prefix}-imagebuilder-logs-<account-id>`
# (e.g. `golden-win2022-imagebuilder-logs-373160674113`), which does NOT
# match that prefix — so without this policy the AWSTOE bootstrap on the
# build/test instance is denied when it tries to upload the rendered
# component YAMLs and command output, and the build fails with:
#   AccessDenied: User: .../golden-win2022-imagebuilder-role/i-...
#   is not authorized to perform: s3:PutObject
# (See CloudWatch log group /aws/imagebuilder/golden-win2022-recipe.)
# The bucket policy in infrastructure-configuration.tf grants the
# imagebuilder.amazonaws.com service principal access, but the EC2 instance
# role needs its own identity-based grant as well.
resource "aws_iam_role_policy" "imagebuilder_logs_access" {
  name = "${var.name_prefix}-imagebuilder-logs-access"
  role = aws_iam_role.imagebuilder_instance_role.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "AllowUploadAndReadOfBuildLogs"
        Effect = "Allow"
        Action = [
          "s3:PutObject",
          "s3:PutObjectAcl",
          "s3:GetObject",
          "s3:GetObjectVersion",
          "s3:ListBucket",
          "s3:GetBucketLocation",
        ]
        Resource = [
          aws_s3_bucket.imagebuilder_logs.arn,
          "${aws_s3_bucket.imagebuilder_logs.arn}/*",
        ]
      }
    ]
  })
}

resource "aws_iam_instance_profile" "imagebuilder_profile" {
  name = var.instance_profile_name
  role = aws_iam_role.imagebuilder_instance_role.name
  tags = var.tags
}
