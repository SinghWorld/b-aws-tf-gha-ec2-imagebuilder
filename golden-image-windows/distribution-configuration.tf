## ---------------------------------------------------------------------------
## DISTRIBUTION CONFIGURATION
## ---------------------------------------------------------------------------
## Controls where the finished, tested AMI gets copied to. This is the piece
## that maps directly onto your multi-account landing zone: build once in
## the "image factory" account, distribute to every spoke account via RAM/
## Organizations sharing, encrypted with a per-region KMS key.
##
## Also defines the AMI naming pattern and the launch permissions granted to
## target accounts.

resource "aws_imagebuilder_distribution_configuration" "this" {
  name        = "${var.name_prefix}-distribution"
  description = "Distributes golden AMI to spoke accounts across regions"

  distribution {
    region = var.aws_region

    ami_distribution_configuration {
      name = "${var.name_prefix}-{{ imagebuilder:buildDate }}"

      ami_tags = merge(var.tags, {
        Name        = var.name_prefix
        BuildSource = "EC2ImageBuilder"
      })

      kms_key_id = var.kms_key_id

      launch_permission {
        user_ids = var.distribution_accounts
      }
    }
  }

  # Additional regions, each with its own target accounts and KMS key
  dynamic "distribution" {
    for_each = var.distribution_regions
    content {
      region = distribution.key

      ami_distribution_configuration {
        name = distribution.value.ami_name

        ami_tags = merge(var.tags, {
          Name        = var.name_prefix
          BuildSource = "EC2ImageBuilder"
        })

        launch_permission {
          user_ids = distribution.value.target_account_ids
        }
      }
    }
  }

  tags = var.tags
}
