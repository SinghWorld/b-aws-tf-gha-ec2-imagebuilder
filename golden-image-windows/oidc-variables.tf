variable "github_org" {
  description = "GitHub organization or username that owns the repo"
  type        = string
}

variable "github_repo" {
  description = "Repository name (without org prefix), e.g. 'golden-image-windows'"
  type        = string
}

variable "allowed_branches" {
  description = <<-EOT
    Branches allowed to assume this role via OIDC for `push` events
    (i.e. the apply workflow on push to main). Keep this tight —
    typically just 'main', since that's what triggers apply.
    Applies ONLY to push events; pull_request events are gated by
    `allowed_pr_branches` below.
  EOT
  type        = list(string)
  default     = ["main"]
}

variable "allowed_pr_branches" {
  description = <<-EOT
    Branches allowed to assume this role via OIDC for `pull_request`
    events (i.e. the plan workflow running on a PR). Defaults to ["*"]
    so feature branches work out of the box — without this, raising a
    PR from a branch other than `main` produces the error:
        Not authorized to perform sts:AssumeRoleWithWebIdentity
    because the sub claim is repo:OWNER/REPO:ref:refs/heads/<branch>
    which doesn't match `allowed_branches` (push-only) or the literal
    `:pull_request` pattern (fork-PR-only).

    Each entry is matched against the OIDC sub claim with StringLike,
    so wildcards are supported, e.g.:
      ["*"]                            — any branch
      ["release/*", "hotfix/*"]        — only those prefixes
      ["feature-*", "fix-*"]           — only those prefixes

    Push events remain restricted to `allowed_branches` regardless of
    this setting, so widening this list does NOT widen who can trigger
    `terraform apply`.
  EOT
  type        = list(string)
  default     = ["*"]
}

variable "allow_pull_requests" {
  description = <<-EOT
    Whether to also trust the 'pull_request' GitHub Actions event (needed
    so the plan job can run on PRs, not just pushes to main). If true,
    grants trust for pull_request events from this repo regardless of
    source branch — scope the attached IAM policy tightly since PR-triggered
    runs are lower-trust (could come from a fork, depending on repo settings).
  EOT
  type        = bool
  default     = true
}

variable "role_name" {
  description = "Name of the IAM role GitHub Actions will assume"
  type        = string
  default     = "golden-image-github-actions-role"
}

variable "create_oidc_provider" {
  description = <<-EOT
    Whether to create the GitHub OIDC provider resource. AWS only allows
    ONE OIDC provider per URL per account. If your Terraform-Drift-Detection
    setup (or any other pipeline) already created
    'token.actions.githubusercontent.com' as an OIDC provider in this
    account, set this to false and supply its ARN via existing_oidc_provider_arn.
  EOT
  type        = bool
  default     = true
}

variable "existing_oidc_provider_arn" {
  description = "ARN of an existing GitHub OIDC provider, used only when create_oidc_provider = false"
  type        = string
  default     = ""
}

# NOTE: imagebuilder_logs_bucket_arn, kms_key_arn, ssm_parameter_arn are NOT
# declared as separate input variables. They're wired directly from this
# same module's existing resources/data sources below (see locals), so the
# OIDC role's permissions can never drift out of sync with the actual
# resources it's scoped to.

