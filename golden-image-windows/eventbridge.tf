## ---------------------------------------------------------------------------
## EVENT-DRIVEN POST-BUILD AUTOMATION
## ---------------------------------------------------------------------------
## Image Builder emits EventBridge events on state changes. We catch the
## "AVAILABLE" (success) state and invoke a Lambda that:
##   1. Looks up the new AMI ID from the pipeline's output image
##   2. Updates the SSM parameter so downstream Terraform picks it up
##   3. Posts to SNS so your team/Slack knows a new golden image is live
##
## This is the glue that makes the SSM parameter in pipeline.tf actually
## stay current without manual intervention.

resource "aws_cloudwatch_event_rule" "image_state_change" {
  name        = "${var.name_prefix}-image-state-change"
  description = "Captures EC2 Image Builder state changes for ${var.name_prefix}"

  event_pattern = jsonencode({
    source      = ["aws.imagebuilder"]
    detail-type = ["EC2 Image Builder Image State Change"]
    detail = {
      state = {
        status = ["AVAILABLE", "FAILED"]
      }
    }
  })

  tags = var.tags
}

resource "aws_cloudwatch_event_target" "invoke_update_lambda" {
  rule      = aws_cloudwatch_event_rule.image_state_change.name
  target_id = "${var.name_prefix}-update-ssm-lambda"
  arn       = aws_lambda_function.update_golden_ami_parameter.arn
}

resource "aws_lambda_permission" "allow_eventbridge" {
  statement_id  = "AllowEventBridgeInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.update_golden_ami_parameter.function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.image_state_change.arn
}

## ---------------------------------------------------------------------------
## Lambda: update SSM parameter + notify SNS
## ---------------------------------------------------------------------------

data "aws_iam_policy_document" "lambda_trust" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "lambda_update_role" {
  name               = "${var.name_prefix}-lambda-update-role"
  assume_role_policy = data.aws_iam_policy_document.lambda_trust.json
  tags               = var.tags
}

resource "aws_iam_role_policy" "lambda_update_policy" {
  name = "${var.name_prefix}-lambda-update-policy"
  role = aws_iam_role.lambda_update_role.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["ssm:PutParameter", "ssm:GetParameter"]
        Resource = aws_ssm_parameter.golden_ami_latest.arn
      },
      {
        Effect   = "Allow"
        Action   = ["imagebuilder:GetImage"]
        Resource = "*"
      },
      {
        Effect   = "Allow"
        Action   = ["sns:Publish"]
        Resource = var.sns_topic_arn != "" ? var.sns_topic_arn : "*"
      },
      {
        Effect   = "Allow"
        Action   = ["logs:CreateLogGroup", "logs:CreateLogStream", "logs:PutLogEvents"]
        Resource = "arn:aws:logs:*:*:*"
      }
    ]
  })
}

resource "aws_lambda_function" "update_golden_ami_parameter" {
  function_name    = "${var.name_prefix}-update-ssm-param"
  role             = aws_iam_role.lambda_update_role.arn
  handler          = "index.handler"
  runtime          = "python3.12"
  timeout          = 30
  filename         = "${path.module}/lambda/update_ssm_param.zip"
  source_code_hash = var.lambda_source_code_hash != "" ? var.lambda_source_code_hash : filebase64sha256("${path.module}/lambda/update_ssm_param.zip")

  environment {
    variables = {
      SSM_PARAMETER_NAME = aws_ssm_parameter.golden_ami_latest.name
      SNS_TOPIC_ARN      = var.sns_topic_arn
    }
  }

  tags = var.tags
}
