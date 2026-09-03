# Approver Lambda module (DISTRIBUTION account, us-east-1).
# Serves the review page, validates the KMS token, records approval in DynamoDB, launches the sync ECS task.

data "aws_partition" "current" {}
data "aws_region" "current" {}
data "aws_caller_identity" "current" {}

# Package the handler directory into a deployable zip.
data "archive_file" "approver" {
  type        = "zip"
  source_dir  = coalesce(var.lambda_source_dir, "${path.module}/../../lambdas/approver")
  output_path = "${path.module}/build/approver.zip"
  # Keep interpreter bytecode out of the artifact: __pycache__ appears whenever
  # the source is compiled locally and would churn the source_code_hash.
  excludes    = ["__pycache__", "__pycache__/**", "**/__pycache__/**", "**/*.pyc"]
}

# Trust policy for the Lambda execution role.
data "aws_iam_policy_document" "assume_role" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "approver" {
  name                 = "${var.function_name}-role"
  assume_role_policy   = data.aws_iam_policy_document.assume_role.json
  permissions_boundary = var.permissions_boundary_arn != "" ? var.permissions_boundary_arn : null
}

# Baseline execution: CloudWatch Logs plus VPC ENI management.
resource "aws_iam_role_policy_attachment" "vpc_access" {
  role       = aws_iam_role.approver.name
  policy_arn = "arn:${data.aws_partition.current.partition}:iam::aws:policy/service-role/AWSLambdaVPCAccessExecutionRole"
}

data "aws_iam_policy_document" "approver" {
  # DynamoDB read and conditional approval update.
  statement {
    sid    = "DynamoDbAccess"
    effect = "Allow"
    actions = [
      "dynamodb:GetItem",
      "dynamodb:UpdateItem"
    ]
    resources = [var.dynamodb_table_arn]
  }

  # Decrypt approval tokens with the dedicated token key.
  statement {
    sid       = "TokenKmsDecrypt"
    effect    = "Allow"
    actions   = ["kms:Decrypt"]
    resources = [var.token_kms_key_arn]
  }

  # Decrypt and generate data keys for each resource key the Lambda touches.
  # Split per key (single-resource statements) for least-privilege clarity.
  statement {
    sid    = "DynamoDbKmsAccess"
    effect = "Allow"
    actions = [
      "kms:Decrypt",
      "kms:GenerateDataKey"
    ]
    resources = [var.dynamodb_kms_key_arn]
  }

  statement {
    sid    = "SnsKmsAccess"
    effect = "Allow"
    actions = [
      "kms:Decrypt",
      "kms:GenerateDataKey"
    ]
    resources = [var.sns_kms_key_arn]
  }

  statement {
    sid    = "S3KmsAccess"
    effect = "Allow"
    actions = [
      "kms:Decrypt",
      "kms:GenerateDataKey"
    ]
    resources = [var.s3_kms_key_arn]
  }

  # Launch the sync ECS task, constrained to the specific cluster via the
  # ecs:cluster condition key (per AWS ECS IAM guidance) plus task-definition resource scope.
  statement {
    sid     = "EcsRunTask"
    effect  = "Allow"
    actions = ["ecs:RunTask"]
    # RunTask is authorized against the REVISIONED task-definition ARN
    # (family:3), so the resource must be family:* per AWS ECS IAM guidance;
    # the bare family ARN never matches and fails AccessDenied.
    resources = ["${var.sync_task_definition_arn}:*"]
    condition {
      test     = "ArnEquals"
      variable = "ecs:cluster"
      values   = [var.ecs_cluster_arn]
    }
  }

  # Pass task and execution roles to ECS. Split per role and constrained via
  # iam:PassedToService so each role can only ever be passed to ECS tasks.
  statement {
    sid       = "EcsPassTaskRole"
    effect    = "Allow"
    actions   = ["iam:PassRole"]
    resources = [var.sync_task_role_arn]
    condition {
      test     = "StringEquals"
      variable = "iam:PassedToService"
      values   = ["ecs-tasks.amazonaws.com"]
    }
  }

  statement {
    sid       = "EcsPassExecRole"
    effect    = "Allow"
    actions   = ["iam:PassRole"]
    resources = [var.sync_exec_role_arn]
    condition {
      test     = "StringEquals"
      variable = "iam:PassedToService"
      values   = ["ecs-tasks.amazonaws.com"]
    }
  }

  # Publish notifications.
  statement {
    sid       = "SnsPublish"
    effect    = "Allow"
    actions   = ["sns:Publish"]
    resources = [var.sns_topic_arn]
  }

  # Read and write request artifacts.
  statement {
    sid    = "S3Requests"
    effect = "Allow"
    actions = [
      "s3:GetObject",
      "s3:PutObject"
    ]
    resources = ["${var.s3_bucket_arn}/requests/*"]
  }

  # Deliver failed asynchronous invocations to the dead-letter queue.
  statement {
    sid       = "DlqSend"
    effect    = "Allow"
    actions   = ["sqs:SendMessage"]
    resources = [aws_sqs_queue.dlq.arn]
  }
}

# Dead-letter queue for failed asynchronous invocations.
resource "aws_sqs_queue" "dlq" {
  name                      = "${var.function_name}-dlq"
  sqs_managed_sse_enabled   = true
  message_retention_seconds = 1209600
}

resource "aws_iam_role_policy" "approver" {
  name   = "${var.function_name}-policy"
  role   = aws_iam_role.approver.id
  policy = data.aws_iam_policy_document.approver.json
}

# AWS Signer signing profile for the Lambda code-signing config.
# Uses the Lambda-specific signing platform (SHA384 ECDSA).
resource "aws_signer_signing_profile" "approver" {
  platform_id = "AWSLambda-SHA384-ECDSA"
  name_prefix = replace("${var.function_name}_signer", "-", "_")
}

# Code-signing config: only artifacts signed by the profile above are trusted.
# Defaults to Warn so the unsigned reference zip still deploys; set Enforce to hard-reject unsigned code.
resource "aws_lambda_code_signing_config" "approver" {
  description = "Code-signing config for the frozen-repo approver Lambda."

  allowed_publishers {
    signing_profile_version_arns = [aws_signer_signing_profile.approver.version_arn]
  }

  policies {
    untrusted_artifact_on_deployment = var.untrusted_artifact_on_deployment
  }
}

resource "aws_lambda_function" "approver" {
  function_name           = var.function_name
  code_signing_config_arn = aws_lambda_code_signing_config.approver.arn
  role                    = aws_iam_role.approver.arn
  runtime                 = "python3.12"
  handler                 = "handler.lambda_handler"
  timeout                 = 900
  memory_size             = 256
  filename                = data.archive_file.approver.output_path
  source_code_hash        = data.archive_file.approver.output_base64sha256

  reserved_concurrent_executions = var.reserved_concurrency
  kms_key_arn                    = var.env_kms_key_arn

  tracing_config {
    mode = "Active"
  }

  dead_letter_config {
    target_arn = aws_sqs_queue.dlq.arn
  }

  vpc_config {
    subnet_ids         = var.subnet_ids
    security_group_ids = [var.security_group_id]
  }

  environment {
    variables = {
      DYNAMODB_TABLE     = var.dynamodb_table_name
      TOKEN_KMS_KEY_ARN  = var.token_kms_key_arn
      ECS_CLUSTER        = var.ecs_cluster
      ECS_TASK_FAMILY    = var.ecs_task_family
      ECS_SUBNETS        = join(",", var.ecs_subnet_ids)
      ECS_SECURITY_GROUP = var.ecs_security_group
      SNS_TOPIC_ARN      = var.sns_topic_arn
      S3_BUCKET          = var.s3_bucket
    }
  }
}

# -----------------------------------------------------------------------------
# HTTP API front for the review page. Replaces a Function URL (authorization_type
# "NONE" requires Principal "*", which org guardrails auto-revoke; see SECURITY.md item 7).
# Same v2.0 payload so the handler is unchanged; auth stays in-app via the KMS-encrypted,
# single-use approval token (re-validated on GET and POST, replay-proof via DynamoDB conditional write).
# -----------------------------------------------------------------------------

resource "aws_apigatewayv2_api" "approver" {
  name          = "${var.function_name}-http"
  protocol_type = "HTTP"
  description   = "Public HTTPS front for the frozen-repo approver review page (app-layer KMS token auth)."
}

resource "aws_cloudwatch_log_group" "api_access" {
  #checkov:skip=CKV_AWS_158:log group CMK supplied per-deployment via var.log_kms_key_arn
  name              = "/aws/apigateway/${var.function_name}"
  retention_in_days = 365
  kms_key_id        = var.log_kms_key_arn
}

resource "aws_apigatewayv2_integration" "approver" {
  api_id                 = aws_apigatewayv2_api.approver.id
  integration_type       = "AWS_PROXY"
  integration_uri        = aws_lambda_function.approver.invoke_arn
  payload_format_version = "2.0"
}

resource "aws_apigatewayv2_route" "default" {
  #checkov:skip=CKV_AWS_309:Authorization is enforced in-app by the KMS-encrypted single-use approval token (re-validated on GET and POST, replay-proof via DynamoDB conditional write). An API GW authorizer needs an OIDC/IAM front the reference cannot assume; documented in SECURITY.md.
  api_id    = aws_apigatewayv2_api.approver.id
  route_key = "$default"
  target    = "integrations/${aws_apigatewayv2_integration.approver.id}"
}

resource "aws_apigatewayv2_stage" "default" {
  api_id      = aws_apigatewayv2_api.approver.id
  name        = "$default"
  auto_deploy = true

  default_route_settings {
    throttling_burst_limit = 10
    throttling_rate_limit  = 10
  }

  access_log_settings {
    destination_arn = aws_cloudwatch_log_group.api_access.arn
    format = jsonencode({
      requestId      = "$context.requestId"
      ip             = "$context.identity.sourceIp"
      requestTime    = "$context.requestTime"
      httpMethod     = "$context.httpMethod"
      routeKey       = "$context.routeKey"
      status         = "$context.status"
      responseLength = "$context.responseLength"
    })
  }
}

# The ONLY principal allowed to invoke the approver is this API - no
# Principal "*" anywhere in the function's resource policy.
resource "aws_lambda_permission" "apigw" {
  statement_id  = "AllowApiGatewayInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.approver.function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_apigatewayv2_api.approver.execution_arn}/*/*"
}
