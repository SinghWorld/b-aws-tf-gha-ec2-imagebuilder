## ---------------------------------------------------------------------------
## IMAGE RECIPE
## ---------------------------------------------------------------------------
## The recipe is the "what gets built": base image + ordered list of
## components + storage configuration. Each component runs in sequence.
##
## Component order matters:
##   1. Updates/patches first
##   2. Hardening second
##   3. Agents (SSM, CloudWatch, AV/EDR) third
##   4. Domain join / app-specific config last
##   5. Reboot component if needed between stages
##   6. Validation/test components run separately in the test phase

resource "aws_imagebuilder_component" "windows_updates" {
  name        = "${var.name_prefix}-windows-updates"
  description = "Installs latest Windows Updates at build time"
  platform    = "Windows"
  version     = "1.0.0"
  data        = file("${path.module}/components/windows-updates.yaml")
  tags        = var.tags
}

resource "aws_imagebuilder_component" "cis_hardening" {
  name        = "${var.name_prefix}-cis-hardening"
  description = "Applies CIS Benchmark hardening baseline for Windows Server"
  platform    = "Windows"
  version     = "1.0.0"
  data        = file("${path.module}/components/cis-hardening.yaml")
  tags        = var.tags
}

resource "aws_imagebuilder_component" "agent_install" {
  name        = "${var.name_prefix}-agent-install"
  description = "Installs/validates SSM Agent and CloudWatch Agent"
  platform    = "Windows"
  version     = "1.0.0"
  data        = file("${path.module}/components/agent-install.yaml")
  tags        = var.tags
}

resource "aws_imagebuilder_component" "validation_test" {
  name        = "${var.name_prefix}-validation-test"
  description = "Pester-based post-build validation (hardening, agents, services)"
  platform    = "Windows"
  version     = "1.0.0"
  data        = file("${path.module}/components/validation-test.yaml")
  tags        = var.tags
}

resource "aws_imagebuilder_image_recipe" "this" {
  name         = "${var.name_prefix}-recipe"
  version      = "1.0.0"
  parent_image = var.base_image_arn

  block_device_mapping {
    device_name = "/dev/sda1"
    ebs {
      volume_size           = 50
      volume_type           = "gp3"
      delete_on_termination = true
      encrypted             = true
      kms_key_id            = var.kms_key_id
    }
  }

  component {
    component_arn = aws_imagebuilder_component.windows_updates.arn
  }

  component {
    component_arn = aws_imagebuilder_component.cis_hardening.arn
  }

  component {
    component_arn = aws_imagebuilder_component.agent_install.arn
  }

  component {
    component_arn = aws_imagebuilder_component.validation_test.arn
  }

  tags = var.tags
}
