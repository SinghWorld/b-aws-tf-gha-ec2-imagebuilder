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
    Branches allowed to assume this role via OIDC. Keep this tight —
    typically just 'main', since that's what triggers apply/build.
    PRs from other branches only need plan, which can use a separate,
    more restricted read-only role if you want stricter separation.
  EOT
  type        = list(string)
  default     = ["main"]
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

