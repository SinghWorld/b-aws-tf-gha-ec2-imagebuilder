terraform {
  required_version = ">= 1.10.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }

  # ----------------------------------------------------------------------------
  # REMOTE STATE BACKEND — S3 with native state locking
  # -----------------------------------------------------------------------
  # State lives in an S3 bucket that was provisioned out-of-band by
  # bootstrap-sandbox.sh (the bucket is NOT managed by this module — that
  # would be a chicken-and-egg with the backend itself).
  #
  # Locking uses Terraform 1.10+ S3-native locking (use_lockfile = true),
  # which writes a `.tflock` object to the same bucket using S3's
  # conditional-writes API. No DynamoDB table is needed — DynamoDB-based
  # locking is deprecated upstream.
  #
  # Required IAM permissions on the bucket for the OIDC role are listed
  # in oidc-github-actions.tf (statement: TerraformStateBucket).
  #
  # The values below come from variables so the same configuration works
  # locally and in CI. Local runs override them with backend.hcl (which
  # the bootstrap script writes); CI overrides them via -backend-config
  # flags reading GitHub secrets. Anything left null here is treated as
  # "must be supplied at init time" by Terraform.
  # -----------------------------------------------------------------------
  backend "s3" {
    bucket         = var.tf_state_bucket
    key            = var.tf_state_key
    region         = var.tf_state_region
    encrypt        = true
    use_lockfile   = true
    dynamodb_table = null # explicit: do not use deprecated DynamoDB locking
  }
}

provider "aws" {
  region = var.aws_region
}
