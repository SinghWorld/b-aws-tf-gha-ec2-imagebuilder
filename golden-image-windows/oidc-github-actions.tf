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

  # -----------------------------------------------------------------------
  # OIDC sub-claim patterns
  # -----------------------------------------------------------------------
  # GitHub's `sub` claim has THREE distinct shapes we need to distinguish,
  # because the same role needs to handle `push` (apply), same-repo
  # `pull_request` (plan from feature branches), and fork `pull_request`
  # (plan from forks). The shapes are:
  #
  #   push (branch ref):
  #     repo:<org>/<repo>:ref:refs/heads/<branch>
  #     e.g. repo:SinghWorld/b-aws-tf-gha-ec2-imagebuilder:ref:refs/heads/main
  #
  #   pull_request from same-repo branch (branch ref):
  #     repo:<org>/<repo>:ref:refs/heads/<branch>
  #     e.g. repo:SinghWorld/b-aws-tf-gha-ec2-imagebuilder:ref:refs/heads/apply-gha-with-remotes3-backend
  #
  #   pull_request from fork (literal suffix):
  #     repo:<org>/<repo>:pull_request
  #     e.g. repo:SinghWorld/b-aws-tf-gha-ec2-imagebuilder:pull_request
  #
  # Note that `push` and same-repo `pull_request` share the SAME sub shape
  # (the branch ref). To tell them apart we have to add a second condition
  # on the `event_name` claim — see the trust policy below.
  # -----------------------------------------------------------------------
  push_branch_subs = [
    for b in var.allowed_branches : "repo:${var.github_org}/${var.github_repo}:ref:refs/heads/${b}"
  ]

  pr_branch_subs = [
    for b in var.allowed_pr_branches : "repo:${var.github_org}/${var.github_repo}:ref:refs/heads/${b}"
  ]

  pr_fork_subs = var.allow_pull_requests ? [
    "repo:${var.github_org}/${var.github_repo}:pull_request"
  ] : []

  # Combined sub patterns used by the merged pull_request statement below:
  #   pr_branch_subs  — same-repo branches with `:ref:refs/heads/<branch>` shape
  #   pr_fork_subs    — literal `:pull_request` suffix for PRs from forks
  # StringLike subsumes StringEquals for literal patterns (no wildcards), so
  # a single StringLike against the union of both lists matches both shapes
  # identically — and keeps the rendered trust policy under the AWS 2048-char
  # quota (see Statement 2 below).
  pr_subs = concat(local.pr_branch_subs, local.pr_fork_subs)

  # workflow_dispatch events share the push sub shape
  # (repo:OWNER/REPO:ref:refs/heads/<branch>), so we build the same kind
  # of StringLike list — wildcards in allowed_dispatch_branches work
  # the same way as in allowed_pr_branches.
  dispatch_branch_subs = [
    for b in var.allowed_dispatch_branches : "repo:${var.github_org}/${var.github_repo}:ref:refs/heads/${b}"
  ]

  # When a workflow job specifies `environment: <name>`, GitHub
  # overrides the OIDC sub claim to:
  #   repo:OWNER/REPO:environment:<name>
  # regardless of the underlying event_name. None of the branch-ref
  # sub patterns above will match this shape, so we need a dedicated
  # list for environment-scoped jobs.
  env_subs = [
    for e in var.allowed_environments : "repo:${var.github_org}/${var.github_repo}:environment:${e}"
  ]
}

## ---------------------------------------------------------------------------
## TRUST POLICY — who can assume this role
## ---------------------------------------------------------------------------
## Three statements, each gated on event_name so push and pull_request
## are scoped independently. The audience check (`sts.amazonaws.com`)
## is in every statement.
##
## Statement 1 — `push` events from allowed_branches (typically just main).
##                This is what triggers `terraform apply`.
##
## Statement 2 — `pull_request` events from same-repo branches matching
##                allowed_pr_branches. This is what triggers `terraform
##                plan` on PRs from feature branches. Defaults to ["*"]
##                so feature branches work out of the box.
##
## Statement 3 — `pull_request` events from forks. GitHub issues a
##                different sub claim for fork PRs (literal `:pull_request`
##                suffix instead of `:ref:refs/heads/<branch>`).

data "aws_iam_policy_document" "github_actions_trust" {
  # --- Statement 1: push events → only allowed_branches ---
  statement {
    sid    = "AllowPushToAllowedBranches"
    effect = "Allow"

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
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:event_name"
      values   = ["push"]
    }

    condition {
      test     = "StringLike"
      variable = "token.actions.githubusercontent.com:sub"
      values   = local.push_branch_subs
    }
  }

  # --- Statement 2: pull_request events (same-repo branches OR forks) ---
  # Merged from the prior separate same-repo-branches and fork statements
  # to fit the AWS 2048-char trust-policy size quota (LimitExceeded:
  # ACLSizePerRole: 2048). Both events share event_name=pull_request and
  # differ only in the sub-claim suffix (`:ref:refs/heads/<branch>` vs
  # literal `:pull_request`); a single StringLike against the union of
  # both pattern lists (local.pr_subs) matches both shapes identically
  # because StringLike subsumes StringEquals for literal patterns.
  statement {
    sid    = "AllowPullRequest"
    effect = "Allow"

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
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:event_name"
      values   = ["pull_request"]
    }

    condition {
      test     = "StringLike"
      variable = "token.actions.githubusercontent.com:sub"
      values   = local.pr_subs
    }
  }

  # --- Statement 4: workflow_dispatch events (manual "Run workflow") ---
  # Without this statement, manually triggering the workflow from a
  # feature branch via the Actions UI fails with:
  #   Not authorized to perform sts:AssumeRoleWithWebIdentity
  # because no statement matches event_name=workflow_dispatch. The sub
  # claim is the same shape as push, so we StringLike against
  # allowed_dispatch_branches (default ["*"] so any branch works).
  statement {
    sid    = "AllowWorkflowDispatchFromAllowedBranches"
    effect = "Allow"

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
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:event_name"
      values   = ["workflow_dispatch"]
    }

    condition {
      test     = "StringLike"
      variable = "token.actions.githubusercontent.com:sub"
      values   = local.dispatch_branch_subs
    }
  }

  # --- Statement 5: GitHub Environments ---
  # When a workflow job declares `environment: <name>`, GitHub overrides
  # the OIDC sub claim to:
  #   repo:OWNER/REPO:environment:<name>
  # This is true regardless of the underlying event_name (push,
  # pull_request, workflow_dispatch, etc.). None of the four branch-ref
  # statements above match this shape, so jobs that use an environment
  # (e.g. for approval gates or environment-scoped secrets) will fail
  # with: Not authorized to perform sts:AssumeRoleWithWebIdentity.
  #
  # We deliberately do NOT gate on event_name here: the environment
  # sub claim is the only distinguishing signal once a job runs under
  # an environment. aud is still required as a baseline check.
  statement {
    sid    = "AllowFromConfiguredEnvironments"
    effect = "Allow"

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
      values   = local.env_subs
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
      # Read APIs needed by `terraform refresh` to read the OIDC provider's
      # current state. Without these the plan step fails with
      # AccessDenied on iam:GetOpenIDConnectProvider before any diff is shown.
      "iam:GetOpenIDConnectProvider",
      "iam:ListOpenIDConnectProviders",
      "iam:GetPolicy",
      "iam:GetPolicyVersion",
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
      # Read APIs needed by `terraform refresh` to read the bucket's
      # current attributes (policy, ACL, tags, encryption, location).
      # Without these the plan step fails with AccessDenied on
      # s3:GetBucketPolicy before any diff is shown.
      "s3:GetBucketPolicy",
      "s3:GetBucketTagging",
      "s3:GetBucketAcl",
      "s3:GetBucketLocation",
      "s3:GetBucketVersioning",
      "s3:GetEncryptionConfiguration",
      "s3:GetAccelerateConfiguration",
      "s3:GetBucketCORS",
      "s3:GetBucketLogging",
      "s3:GetBucketNotification",
      "s3:GetBucketObjectLockConfiguration",
      "s3:GetBucketOwnershipControls",
      "s3:GetBucketReplication",
      "s3:GetBucketRequestPayment",
      "s3:GetBucketWebsite",
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
      "s3:GetBucketPolicy",
      "s3:GetBucketAcl",
      "s3:GetBucketTagging",
      "s3:GetEncryptionConfiguration",
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
      "ssm:GetParameters",
      "ssm:PutParameter",
      "ssm:DescribeParameters",
      "ssm:GetParameterHistory",
      "ssm:ListTagsForResource",
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
      "lambda:GetEventSourceMapping",
      "lambda:ListEventSourceMappings",
      "lambda:GetFunctionCodeSigningConfig",
      "events:PutRule",
      "events:DeleteRule",
      "events:DescribeRule",
      "events:PutTargets",
      "events:RemoveTargets",
      "events:ListTargetsByRule",
      "events:ListRules",
      "events:ListTagsForResource",
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
