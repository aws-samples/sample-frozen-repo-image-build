# This module is deployed into the DISTRIBUTION account, us-east-1.
# Configure the aws provider accordingly in the calling configuration.

data "aws_partition" "current" {}
data "aws_region" "current" {}
data "aws_caller_identity" "current" {}

locals {
  bucket_arn = "arn:${data.aws_partition.current.partition}:s3:::${var.s3_bucket}"
}

# --- Package the handler ------------------------------------------------------

data "archive_file" "manifest_updater" {
  type        = "zip"
  source_dir  = coalesce(var.lambda_source_dir, "${path.module}/../../lambdas/manifest_updater")
  output_path = "${path.module}/.build/manifest_updater.zip"
  # Keep interpreter bytecode out of the artifact: __pycache__ appears whenever
  # the source is compiled locally and would churn the source_code_hash.
  excludes = ["__pycache__", "__pycache__/**", "**/__pycache__/**", "**/*.pyc"]
}

# --- IAM role -----------------------------------------------------------------

data "aws_iam_policy_document" "assume_role" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [data.aws_caller_identity.current.account_id]
    }
  }
}

resource "aws_iam_role" "manifest_updater" {
  name                 = "${var.function_name}-role"
  assume_role_policy   = data.aws_iam_policy_document.assume_role.json
  permissions_boundary = var.permissions_boundary_arn
  tags                 = var.tags
}

resource "aws_iam_role_policy_attachment" "vpc_access" {
  role       = aws_iam_role.manifest_updater.name
  policy_arn = "arn:${data.aws_partition.current.partition}:iam::aws:policy/service-role/AWSLambdaVPCAccessExecutionRole"
}

data "aws_iam_policy_document" "manifest_updater" {
  statement {
    sid    = "S3ObjectAccess"
    effect = "Allow"
    actions = [
      "s3:GetObject",
      "s3:PutObject",
      "s3:ListBucket",
    ]
    resources = [
      local.bucket_arn,
      "${local.bucket_arn}/*",
    ]
  }

  statement {
    sid    = "KmsAccess"
    effect = "Allow"
    actions = [
      "kms:Decrypt",
      "kms:DescribeKey",
      "kms:GenerateDataKey",
    ]
    resources = [var.s3_kms_key_arn]

    condition {
      test     = "StringEquals"
      variable = "kms:ViaService"
      values   = ["s3.${var.s3_region}.amazonaws.com"]
    }
  }

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
  tags                      = var.tags
}

resource "aws_iam_role_policy" "manifest_updater" {
  name   = "${var.function_name}-policy"
  role   = aws_iam_role.manifest_updater.id
  policy = data.aws_iam_policy_document.manifest_updater.json
}

# --- Lambda function ----------------------------------------------------------

resource "aws_lambda_function" "manifest_updater" {
  #checkov:skip=CKV_AWS_272:code-signing config is deployment-specific and out of scope for this reference
  #checkov:skip=CKV_AWS_173:env vars carry no secrets; encrypt-at-rest via CMK set in production via var.env_kms_key_arn
  function_name    = var.function_name
  role             = aws_iam_role.manifest_updater.arn
  runtime          = "python3.12"
  handler          = "handler.lambda_handler"
  timeout          = 900
  memory_size      = 2048
  filename         = data.archive_file.manifest_updater.output_path
  source_code_hash = data.archive_file.manifest_updater.output_base64sha256

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
      S3_BUCKET     = var.s3_bucket
      S3_REGION     = var.s3_region
      REPOS_TO_SCAN = jsonencode(var.repo_matrix)
    }
  }

  tags = var.tags
}

# Explicit async policy for EventBridge invocations. With reserved concurrency 1,
# later task-stop events remain eligible for retry for up to six hours.
resource "aws_lambda_function_event_invoke_config" "manifest_updater" {
  function_name                = aws_lambda_function.manifest_updater.function_name
  maximum_event_age_in_seconds = 21600
  maximum_retry_attempts       = 2
}

# --- EventBridge rule: ECS Task State Change ----------------------------------

resource "aws_cloudwatch_event_rule" "sync_task_stopped" {
  name        = "${var.function_name}-sync-task-stopped"
  description = "Triggers the manifest updater when the sync ECS task stops."

  event_pattern = jsonencode({
    source      = ["aws.ecs"]
    detail-type = ["ECS Task State Change"]
    detail = {
      clusterArn        = [var.sync_cluster_arn]
      lastStatus        = ["STOPPED"]
      taskDefinitionArn = [{ prefix = var.sync_task_definition_arn_prefix }]
    }
  })

  tags = var.tags
}

resource "aws_cloudwatch_event_target" "manifest_updater" {
  rule      = aws_cloudwatch_event_rule.sync_task_stopped.name
  target_id = "manifest-updater-lambda"
  arn       = aws_lambda_function.manifest_updater.arn
}

resource "aws_lambda_permission" "allow_eventbridge" {
  statement_id  = "AllowExecutionFromEventBridge"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.manifest_updater.function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.sync_task_stopped.arn
}
