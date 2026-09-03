# Detector Lambda module (DISTRIBUTION account, us-east-1).
# Monthly: diffs upstream repos vs published manifest, classifies changes, emits a signed review link.

data "aws_partition" "current" {}
data "aws_region" "current" {}
data "aws_caller_identity" "current" {}

# Package the handler directory into a deployable zip.
data "archive_file" "detector" {
  type        = "zip"
  source_dir  = coalesce(var.lambda_source_dir, "${path.module}/../../lambdas/detector")
  output_path = "${path.module}/build/detector.zip"
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
    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [data.aws_caller_identity.current.account_id]
    }
  }
}

resource "aws_iam_role" "detector" {
  name                 = "${var.function_name}-role"
  assume_role_policy   = data.aws_iam_policy_document.assume_role.json
  permissions_boundary = var.permissions_boundary_arn != "" ? var.permissions_boundary_arn : null
}

# Baseline execution: CloudWatch Logs plus VPC ENI management.
resource "aws_iam_role_policy_attachment" "vpc_access" {
  role       = aws_iam_role.detector.name
  policy_arn = "arn:${data.aws_partition.current.partition}:iam::aws:policy/service-role/AWSLambdaVPCAccessExecutionRole"
}

data "aws_iam_policy_document" "detector" {
  # DynamoDB request tracking.
  statement {
    sid    = "DynamoDbAccess"
    effect = "Allow"
    actions = [
      "dynamodb:PutItem",
      "dynamodb:GetItem"
    ]
    resources = [var.dynamodb_table_arn]
  }

  # Encrypt approval tokens with the dedicated token key.
  statement {
    sid       = "TokenKmsEncrypt"
    effect    = "Allow"
    actions   = ["kms:Encrypt"]
    resources = [var.token_kms_key_arn]
  }

  # Decrypt and generate data keys for the resource keys the Lambda touches.
  statement {
    sid    = "ResourceKmsAccess"
    effect = "Allow"
    actions = [
      "kms:Decrypt",
      "kms:GenerateDataKey"
    ]
    resources = [
      var.dynamodb_kms_key_arn,
      var.sns_kms_key_arn
    ]
    condition {
      test     = "StringEquals"
      variable = "kms:ViaService"
      values = [
        "dynamodb.${data.aws_region.current.region}.amazonaws.com",
        "sns.${data.aws_region.current.region}.amazonaws.com"
      ]
    }
  }

  # Frozen-store S3 key lives in the bucket region (us-west-2), not the detector's
  # own region (us-east-1), so its kms:ViaService is scoped separately.
  statement {
    sid    = "S3ResourceKmsAccess"
    effect = "Allow"
    actions = [
      "kms:Decrypt",
      "kms:GenerateDataKey",
    ]
    resources = [var.s3_kms_key_arn]
    condition {
      test     = "StringEquals"
      variable = "kms:ViaService"
      values   = ["s3.${var.s3_region}.amazonaws.com"]
    }
  }

  # Publish review notifications.
  statement {
    sid       = "SnsPublish"
    effect    = "Allow"
    actions   = ["sns:Publish"]
    resources = [var.sns_topic_arn]
  }

  # Read the bucket listing and the manifest.
  statement {
    sid    = "S3ReadManifest"
    effect = "Allow"
    actions = [
      "s3:GetObject",
      "s3:ListBucket"
    ]
    resources = [
      var.s3_bucket_arn,
      "${var.s3_bucket_arn}/manifest.json"
    ]
  }

  # Write candidate request artifacts.
  statement {
    sid       = "S3WriteRequests"
    effect    = "Allow"
    actions   = ["s3:PutObject"]
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

resource "aws_iam_role_policy" "detector" {
  name   = "${var.function_name}-policy"
  role   = aws_iam_role.detector.id
  policy = data.aws_iam_policy_document.detector.json
}

resource "aws_lambda_function" "detector" {
  #checkov:skip=CKV_AWS_272:code-signing config is deployment-specific and out of scope for this reference
  #checkov:skip=CKV_AWS_173:env vars carry no secrets; encrypt-at-rest via CMK set in production via var.env_kms_key_arn
  function_name    = var.function_name
  role             = aws_iam_role.detector.arn
  runtime          = "python3.12"
  handler          = "handler.lambda_handler"
  timeout          = 900
  memory_size      = 2048
  filename         = data.archive_file.detector.output_path
  source_code_hash = data.archive_file.detector.output_base64sha256

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
      SNS_TOPIC_ARN      = var.sns_topic_arn
      TOKEN_KMS_KEY_ARN  = var.token_kms_key_arn
      S3_BUCKET          = var.s3_bucket
      APPLY_LAMBDA_URL   = var.apply_lambda_url
      TOKEN_EXPIRY_HOURS = tostring(var.token_expiry_hours)
      UPSTREAM_REPOS     = jsonencode(var.upstream_repos)
    }
  }
}

# Monthly schedule that fires the detector.
resource "aws_cloudwatch_event_rule" "detector_schedule" {
  name                = "${var.function_name}-schedule"
  description         = "Scheduled trigger for the detector Lambda"
  schedule_expression = var.schedule_expression
}

resource "aws_cloudwatch_event_target" "detector_target" {
  rule      = aws_cloudwatch_event_rule.detector_schedule.name
  target_id = "detector-lambda"
  arn       = aws_lambda_function.detector.arn
}

resource "aws_lambda_permission" "allow_eventbridge" {
  statement_id  = "AllowExecutionFromEventBridge"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.detector.function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.detector_schedule.arn
}
