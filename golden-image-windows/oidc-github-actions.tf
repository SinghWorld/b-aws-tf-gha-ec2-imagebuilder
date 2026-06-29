## ---------------------------------------------------------------------------
## GITHUB OIDC PROVIDER
## ---------------------------------------------------------------------------
## One per AWS account, shared across every repo/workflow that uses GitHub
## OIDC. If you already created this for Terraform-Drift-Detection or any
## other pipeline, set create_oidc_provider = false and pass its ARN in.

resource "aws_iam_openid_connect_provider" "github" {
  count = var.create_oidc_provider ? 1 : 0

  url            = "https://token.actions.githubusercontent.com"
  client_id_list = ["sts.amazonaws.com"]

  # GitHub's documented OIDC root CA thumbprint. AWS validates the live TLS
  # chain for this provider rather than strictly matching this value, but
  # the argument is still required by the resource.
  thumbprint_list = ["6938fd4d98bab03faadb97b34396831e3780aea1"]

  tags = var.tags
}

locals {
  oidc_provider_arn = var.create_oidc_provider ? aws_iam_openid_connect_provider.github[0].arn : var.existing_oidc_provider_arn

  # Subject claims this role will trust. GitHub's sub claim format:
  #   repo:<org>/<repo>:ref:refs/heads/<branch>   (push/branch events)
  #   repo:<org>/<repo>:pull_request               (any PR against the repo)
  branch_subs = [
    for b in var.allowed_branches : "repo:${var.github_org}/${var.github_repo}:ref:refs/heads/${b}"
  ]

  pr_subs = var.allow_pull_requests ? ["repo:${var.github_org}/${var.github_repo}:pull_request"] : []

  trusted_subs = concat(local.branch_subs, local.pr_subs)
}

## ---------------------------------------------------------------------------
## TRUST POLICY — who can assume this role
## ---------------------------------------------------------------------------
## Scoped to: this specific repo, only the listed branches (+ optionally
## pull_request events), and only via the GitHub Actions OIDC audience.
## This is the part that actually matters for security — get this loose and
## the IAM policy attached doesn't matter much.

data "aws_iam_policy_document" "github_actions_trust" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [local.oidc_provider_arn]
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }

    condition {
      test     = "StringLike"
      variable = "token.actions.githubusercontent.com:sub"
      values   = local.trusted_subs
    }
  }
}

resource "aws_iam_role" "github_actions" {
  name                 = var.role_name
  assume_role_policy   = data.aws_iam_policy_document.github_actions_trust.json
  max_session_duration = 3600 # role is re-assumed per job step, not held for a whole long-running build
  tags                 = var.tags
}

## ---------------------------------------------------------------------------
## PERMISSIONS — least privilege for what these workflows actually do
## ---------------------------------------------------------------------------
## Split into logical statements so it's obvious which action needs which
## permission. Resist the urge to attach a managed Image Builder full-access
## policy — that grants far more than CI needs.

data "aws_iam_policy_document" "github_actions_permissions" {

  # --- Image Builder: manage pipeline, recipe, components, configs ---
  statement {
    sid    = "ImageBuilderManage"
    effect = "Allow"
    actions = [
      "imagebuilder:Get*",
      "imagebuilder:List*",
      "imagebuilder:CreateImagePipeline",
      "imagebuilder:UpdateImagePipeline",
      "imagebuilder:DeleteImagePipeline",
      "imagebuilder:CreateImageRecipe",
      "imagebuilder:DeleteImageRecipe",
      "imagebuilder:CreateComponent",
      "imagebuilder:DeleteComponent",
      "imagebuilder:CreateInfrastructureConfiguration",
      "imagebuilder:UpdateInfrastructureConfiguration",
      "imagebuilder:DeleteInfrastructureConfiguration",
      "imagebuilder:CreateDistributionConfiguration",
      "imagebuilder:UpdateDistributionConfiguration",
      "imagebuilder:DeleteDistributionConfiguration",
      "imagebuilder:StartImagePipelineExecution",
      "imagebuilder:TagResource",
      "imagebuilder:UntagResource",
    ]
    resources = ["*"] # Image Builder ARNs are generated post-create; tighten via resource tags if your org enforces tag-based IAM
  }

  # --- EC2: required by Image Builder to launch/terminate build instances ---
  statement {
    sid    = "EC2BuildInstanceLifecycle"
    effect = "Allow"
    actions = [
      "ec2:RunInstances",
      "ec2:TerminateInstances",
      "ec2:DescribeInstances",
      "ec2:DescribeImages",
      "ec2:DescribeSubnets",
      "ec2:DescribeSecurityGroups",
      "ec2:DescribeNetworkInterfaces",
      "ec2:CreateTags",
      "ec2:DescribeInstanceTypes",
      "ec2:DescribeInstanceStatus",
      "ec2:DescribeVolumes",
      "ec2:CreateSnapshot",
      "ec2:DescribeSnapshots",
      "ec2:RegisterImage",
      "ec2:DeregisterImage",
      "ec2:CopyImage",
      "ec2:ModifyImageAttribute",
      "ec2:DescribeImageAttribute",
    ]
    resources = ["*"] # EC2 actions for Image Builder's managed build instances aren't predictably ARN-scopable at plan time
  }

  # --- IAM: PassRole scoped to exactly the build instance role, exactly to EC2 ---
  statement {
    sid       = "PassInstanceProfileToImageBuilder"
    effect    = "Allow"
    actions   = ["iam:PassRole"]
    resources = ["arn:aws:iam::*:role/${var.name_prefix}-imagebuilder-role"]

    condition {
      test     = "StringEquals"
      variable = "iam:PassedToService"
      values   = ["ec2.amazonaws.com"]
    }
  }

  # --- IAM: manage the module's own roles/policies/instance profile (terraform apply needs this) ---
  statement {
    sid    = "ManageOwnIAMResources"
    effect = "Allow"
    actions = [
      "iam:CreateRole",
      "iam:DeleteRole",
      "iam:GetRole",
      "iam:UpdateRole",
      "iam:AttachRolePolicy",
      "iam:DetachRolePolicy",
      "iam:PutRolePolicy",
      "iam:DeleteRolePolicy",
      "iam:GetRolePolicy",
      "iam:ListRolePolicies",
      "iam:ListAttachedRolePolicies",
      "iam:CreateInstanceProfile",
      "iam:DeleteInstanceProfile",
      "iam:AddRoleToInstanceProfile",
      "iam:RemoveRoleFromInstanceProfile",
      "iam:GetInstanceProfile",
      "iam:TagRole",
      "iam:TagInstanceProfile",
    ]
    resources = [
      "arn:aws:iam::*:role/${var.name_prefix}-*",
      "arn:aws:iam::*:instance-profile/${var.name_prefix}-*",
      "arn:aws:iam::*:role/${var.role_name}-lambda*",
    ]
  }

  # --- S3: logging bucket only ---
  statement {
    sid    = "ImageBuilderLogsBucket"
    effect = "Allow"
    actions = [
      "s3:GetObject",
      "s3:PutObject",
      "s3:ListBucket",
      "s3:PutBucketTagging",
      "s3:PutLifecycleConfiguration",
      "s3:GetLifecycleConfiguration",
      "s3:PutBucketPublicAccessBlock",
      "s3:GetBucketPublicAccessBlock",
      "s3:CreateBucket",
      "s3:DeleteBucket",
    ]
    resources = [
      aws_s3_bucket.imagebuilder_logs.arn,
      "${aws_s3_bucket.imagebuilder_logs.arn}/*",
    ]
  }

  # --- S3: Terraform remote state bucket (with native .tflock lock file) ---
  # Required for `terraform init/plan/apply/destroy` to read state, write
  # state, and acquire/release the native lock file at <key>.tflock.
  # The bucket itself is created out-of-band by bootstrap-sandbox.sh and
  # is therefore NOT one of the resources managed by this module — it is
  # referenced here via the tf_state_bucket variable so the IAM policy is
  # scoped to exactly the bucket CI uses. If the variable is empty (i.e.
  # this module was applied without ever wiring up remote state), the
  # statement degrades to no permissions, which is correct.
  statement {
    sid    = "TerraformStateBucket"
    effect = "Allow"
    actions = [
      "s3:ListBucket",
      "s3:GetBucketVersioning",
      "s3:GetBucketLocation",
      "s3:GetObject",
      "s3:GetObjectVersion",
      "s3:PutObject",
      "s3:DeleteObject",
    ]
    resources = var.tf_state_bucket != null && var.tf_state_bucket != "" ? [
      "arn:aws:s3:::${var.tf_state_bucket}",
      "arn:aws:s3:::${var.tf_state_bucket}/*",
    ] : []
  }

  # --- KMS: only the key used for AMI encryption, only the actions needed ---
  statement {
    sid    = "AMIEncryptionKey"
    effect = "Allow"
    actions = [
      "kms:DescribeKey",
      "kms:CreateGrant",
      "kms:Encrypt",
      "kms:Decrypt",
      "kms:GenerateDataKey",
      "kms:GenerateDataKeyWithoutPlaintext",
    ]
    resources = [var.kms_key_id]
  }

  # --- SSM: only the specific golden-AMI parameter ---
  statement {
    sid    = "GoldenAmiParameter"
    effect = "Allow"
    actions = [
      "ssm:GetParameter",
      "ssm:PutParameter",
      "ssm:AddTagsToResource",
    ]
    resources = [aws_ssm_parameter.golden_ami_latest.arn]
  }

  # --- Lambda + EventBridge: manage the post-build automation ---
  statement {
    sid    = "LambdaAndEventBridge"
    effect = "Allow"
    actions = [
      "lambda:CreateFunction",
      "lambda:UpdateFunctionCode",
      "lambda:UpdateFunctionConfiguration",
      "lambda:GetFunction",
      "lambda:DeleteFunction",
      "lambda:AddPermission",
      "lambda:RemovePermission",
      "lambda:TagResource",
      "lambda:GetPolicy",
      "events:PutRule",
      "events:DeleteRule",
      "events:DescribeRule",
      "events:PutTargets",
      "events:RemoveTargets",
      "events:ListTargetsByRule",
      "events:TagResource",
    ]
    resources = ["*"] # Lambda/EventBridge ARNs aren't known before first apply; tighten to name-prefix ARNs once the module has run once if your org requires it
  }

  # --- CloudWatch Logs: Lambda's own log group ---
  statement {
    sid    = "LambdaLogging"
    effect = "Allow"
    actions = [
      "logs:CreateLogGroup",
      "logs:CreateLogStream",
      "logs:PutLogEvents",
      "logs:DescribeLogGroups",
    ]
    resources = ["arn:aws:logs:*:*:log-group:/aws/lambda/${var.name_prefix}-*"]
  }

  # --- SNS: publish build notifications ---
  statement {
    sid       = "PublishBuildNotifications"
    effect    = "Allow"
    actions   = ["sns:Publish"]
    resources = ["arn:aws:sns:*:*:golden-image-notifications"]
  }

  # --- Lambda needs to pass its own execution role at create time ---
  statement {
    sid       = "PassLambdaExecutionRole"
    effect    = "Allow"
    actions   = ["iam:PassRole"]
    resources = ["arn:aws:iam::*:role/${var.name_prefix}-lambda-update-role"]

    condition {
      test     = "StringEquals"
      variable = "iam:PassedToService"
      values   = ["lambda.amazonaws.com"]
    }
  }
}

resource "aws_iam_role_policy" "github_actions_permissions" {
  name   = "${var.role_name}-permissions"
  role   = aws_iam_role.github_actions.id
  policy = data.aws_iam_policy_document.github_actions_permissions.json
}
