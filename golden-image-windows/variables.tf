## ---------------------------------------------------------------------------
## BACKEND / STATE BUCKET
## ---------------------------------------------------------------------------
## The S3 bucket that stores Terraform state is created OUT-OF-BAND by
## bootstrap-sandbox.sh — it cannot live inside this module's own state
## (chicken-and-egg with the backend block). The three values below tell
## the backend block in provider.tf where to read/write state.
##
## Local: bootstrap-sandbox.sh writes backend.hcl, and you run
##   terraform init -backend-config=backend.hcl
## CI   : golden-image-terraform.yml reads TF_STATE_BUCKET /
##        TF_STATE_REGION / TF_STATE_KEY from secrets and passes them
##        as -backend-config flags.
variable "tf_state_bucket" {
  description = "S3 bucket that holds the Terraform remote state. Must exist before `terraform init`."
  type        = string
  default     = null # must be supplied — no sensible default for a state bucket
}

variable "tf_state_region" {
  description = "AWS region of the state bucket. May differ from var.aws_region."
  type        = string
  default     = null # must be supplied
}

variable "tf_state_key" {
  description = "Object key (path) of the state file inside the bucket."
  type        = string
  default     = "golden-image-windows/terraform.tfstate"
}

variable "name_prefix" {
  description = "Prefix used for naming all resources (e.g. 'golden-win2022')"
  type        = string
  default     = "golden-win2022"
}

variable "aws_region" {
  description = "Primary region where the pipeline runs and the base AMI is built"
  type        = string
  default     = "us-east-1"
}

variable "base_image_arn" {
  description = <<-EOT
    SSM alias ARN for the base AMI. Using the SSM alias (not a static AMI ID)
    means Image Builder always starts from the latest patched AWS-managed base.
    Example: arn:aws:imagebuilder:us-east-1:aws:image/windows-server-2022-english-full-base-x86/x.x.x
  EOT
  type        = string
  default     = "arn:aws:imagebuilder:us-east-1:aws:image/windows-server-2022-english-full-base-x86/x.x.x"
}

variable "instance_types" {
  description = "Instance types Image Builder is allowed to use for the build/test stage"
  type        = list(string)
  default     = ["t3.large", "t3a.large"]
}

variable "subnet_id" {
  description = "Subnet for the build/test instance (must have route to SSM endpoints — private subnet with VPC endpoints, or public with egress)"
  type        = string
}

variable "security_group_ids" {
  description = "Security groups attached to the build/test instance"
  type        = list(string)
}

variable "instance_profile_name" {
  description = "Name for the IAM instance profile used by the build instance (created by this module)"
  type        = string
  default     = "golden-win2022-imagebuilder-profile"
}

variable "kms_key_id" {
  description = "KMS key ARN used to encrypt the resulting AMI snapshot. Required for enterprise — never leave AMIs unencrypted."
  type        = string
}

variable "distribution_accounts" {
  description = "List of target AWS account IDs to share/copy the AMI to (spoke accounts in your landing zone)"
  type        = list(string)
  default     = []
}

variable "distribution_regions" {
  description = "Map of region => list of target account IDs for that region. Allows multi-region distribution."
  type = map(object({
    target_account_ids = list(string)
    ami_name           = string
  }))
  default = {}
}

variable "schedule_cron" {
  description = "Cron expression for automated rebuilds (e.g. monthly, patch-Tuesday-aligned). Image Builder uses its own cron syntax."
  type        = string
  default     = "cron(0 18 ? * SAT#2 *)" # 2nd Saturday monthly, ~1 week after patch Tuesday
}

variable "sns_topic_arn" {
  description = "SNS topic ARN for build status notifications (success/failure)"
  type        = string
  default     = ""
}

variable "tags" {
  description = "Common tags applied to all resources"
  type        = map(string)
  default     = {}
}
