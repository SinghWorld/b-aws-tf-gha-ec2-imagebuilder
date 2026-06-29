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

resource "aws_iam_instance_profile" "imagebuilder_profile" {
  name = var.instance_profile_name
  role = aws_iam_role.imagebuilder_instance_role.name
  tags = var.tags
}
