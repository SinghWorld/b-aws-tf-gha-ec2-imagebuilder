## ---------------------------------------------------------------------------
## IMAGE PIPELINE
## ---------------------------------------------------------------------------
## This is the orchestrator: ties the recipe + infra config + distribution
## config together and adds a schedule. Triggers a new build automatically
## (e.g. monthly, patch-Tuesday-aligned) or can be invoked on-demand from
## GitHub Actions via `aws imagebuilder start-image-pipeline-execution`.

resource "aws_imagebuilder_image_pipeline" "this" {
  name                             = "${var.name_prefix}-pipeline"
  description                      = "Golden image pipeline for ${var.name_prefix}"
  image_recipe_arn                 = aws_imagebuilder_image_recipe.this.arn
  infrastructure_configuration_arn = aws_imagebuilder_infrastructure_configuration.this.arn
  distribution_configuration_arn   = aws_imagebuilder_distribution_configuration.this.arn
  status                           = "ENABLED"

  image_tests_configuration {
    image_tests_enabled = true
    timeout_minutes      = 90
  }

  schedule {
    schedule_expression                = var.schedule_cron
    pipeline_execution_start_condition = "EXPRESSION_MATCH_AND_DEPENDENCY_UPDATES_AVAILABLE"
  }

  tags = var.tags
}

## ---------------------------------------------------------------------------
## SSM Parameter — "latest golden AMI" pointer
## ---------------------------------------------------------------------------
## Downstream Terraform (your EC2/ASG/launch template code) should ALWAYS
## read the AMI ID from this parameter, never hardcode an AMI ID. This
## parameter gets updated post-build by an EventBridge rule + Lambda (or a
## GitHub Actions step) once the pipeline completes successfully — see the
## eventbridge.tf file for the update mechanism.

resource "aws_ssm_parameter" "golden_ami_latest" {
  name        = "/golden-images/${var.name_prefix}/latest-ami-id"
  description = "Always points to the most recently validated golden AMI for ${var.name_prefix}"
  type        = "String"
  value       = "placeholder-updated-post-build" # overwritten by automation after first successful build
  tags        = var.tags

  lifecycle {
    ignore_changes = [value] # value is managed by the post-build automation, not Terraform
  }
}
