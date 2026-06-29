output "pipeline_arn" {
  description = "ARN of the Image Builder pipeline — used to trigger manual builds from GitHub Actions"
  value       = aws_imagebuilder_image_pipeline.this.arn
}

output "recipe_arn" {
  value = aws_imagebuilder_image_recipe.this.arn
}

output "golden_ami_ssm_parameter_name" {
  description = "SSM parameter that always holds the latest validated golden AMI ID. Reference this from downstream Terraform via aws_ssm_parameter data source."
  value       = aws_ssm_parameter.golden_ami_latest.name
}

output "logging_bucket" {
  value = aws_s3_bucket.imagebuilder_logs.bucket
}

output "infrastructure_configuration_arn" {
  value = aws_imagebuilder_infrastructure_configuration.this.arn
}

output "distribution_configuration_arn" {
  value = aws_imagebuilder_distribution_configuration.this.arn
}

output "github_actions_role_arn" {
  description = "ARN to put in the AWS_OIDC_ROLE_ARN GitHub secret"
  value       = aws_iam_role.github_actions.arn
}

output "github_oidc_provider_arn" {
  description = "ARN of the GitHub OIDC provider (only meaningful if create_oidc_provider = true)"
  value       = var.create_oidc_provider ? aws_iam_openid_connect_provider.github[0].arn : var.existing_oidc_provider_arn
}
