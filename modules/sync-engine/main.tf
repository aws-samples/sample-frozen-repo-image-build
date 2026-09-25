# Sync Engine module - main resources
# DISTRIBUTION account, us-east-1. All ARNs and identifiers are supplied via variables.

data "aws_region" "current" {}

data "aws_caller_identity" "current" {}

locals {
  # Region the ECS resources run in.
  region    = data.aws_region.current.region
  ecr_image = "${aws_ecr_repository.sync.repository_url}:${var.image_tag}"
  log_group = "/ecs/${var.task_family}"
}

# ---------------------------------------------------------------------------
# 1. ECS cluster + CloudWatch log group
# ---------------------------------------------------------------------------

resource "aws_ecs_cluster" "sync" {
  name = "${var.task_family}-cluster"

  setting {
    name  = "containerInsights"
    value = "enabled"
  }

  tags = var.tags
}

resource "aws_cloudwatch_log_group" "sync" {
  #checkov:skip=CKV_AWS_158:log group CMK supplied per-deployment via var.log_kms_key_arn
  name              = local.log_group
  retention_in_days = var.log_retention_days
  kms_key_id        = var.log_kms_key_arn
  tags              = var.tags
}

# ---------------------------------------------------------------------------
# 2. ECR repository + lifecycle policy
# ---------------------------------------------------------------------------

resource "aws_ecr_repository" "sync" {
  name                 = var.ecr_repo_name
  image_tag_mutability = "IMMUTABLE"
  force_delete         = var.ecr_force_delete

  image_scanning_configuration {
    scan_on_push = true
  }

  encryption_configuration {
    encryption_type = var.ecr_kms_key_arn != null ? "KMS" : "AES256"
    kms_key         = var.ecr_kms_key_arn
  }

  tags = var.tags
}

resource "aws_ecr_lifecycle_policy" "sync" {
  repository = aws_ecr_repository.sync.name

  policy = jsonencode({
    rules = [
      {
        rulePriority = 1
        description  = "Keep only the last 10 images."
        selection = {
          tagStatus   = "any"
          countType   = "imageCountMoreThan"
          countNumber = 10
        }
        action = {
          type = "expire"
        }
      }
    ]
  })
}

# ---------------------------------------------------------------------------
# 3. ECS task definition
# ---------------------------------------------------------------------------

resource "aws_ecs_task_definition" "sync" {
  family                   = var.task_family
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = 4096
  memory                   = 8192
  execution_role_arn       = aws_iam_role.execution.arn
  task_role_arn            = aws_iam_role.task.arn

  ephemeral_storage {
    size_in_gib = 200
  }

  container_definitions = jsonencode([
    {
      name      = "sync"
      image     = local.ecr_image
      essential = true
      environment = [
        { name = "S3_BUCKET", value = var.s3_bucket },
        { name = "S3_REGION", value = var.s3_region },
        { name = "DYNAMODB_TABLE", value = var.dynamodb_table },
        { name = "DYNAMODB_REGION", value = var.dynamodb_region },
        { name = "UPSTREAM_REPOS_MAP", value = jsonencode(var.upstream_repos_map) }
      ]
      logConfiguration = {
        logDriver = "awslogs"
        options = {
          "awslogs-group"         = aws_cloudwatch_log_group.sync.name
          "awslogs-region"        = local.region
          "awslogs-stream-prefix" = "sync"
        }
      }
    }
  ])

  tags = var.tags
}

# ---------------------------------------------------------------------------
# 4. IAM roles: execution role and task role
# ---------------------------------------------------------------------------

data "aws_iam_policy_document" "ecs_assume" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ecs-tasks.amazonaws.com"]
    }
    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [data.aws_caller_identity.current.account_id]
    }
  }
}

# Execution role: pull the image from ECR and write container logs.
resource "aws_iam_role" "execution" {
  name                 = "${var.task_family}-exec-role"
  assume_role_policy   = data.aws_iam_policy_document.ecs_assume.json
  permissions_boundary = var.permissions_boundary_arn
  tags                 = var.tags
}

data "aws_iam_policy_document" "execution" {
  # checkov:skip=CKV_AWS_356:ecr:GetAuthorizationToken does not support resource-level permissions per the AWS IAM reference, so it must target "*". The EcrPull, Logs, and all task-role statements below are scoped to specific ARNs.
  # checkov:skip=CKV_AWS_111:No unconstrained write/permission-management actions; the only "*" statement is the resource-less ECR auth-token call.
  statement {
    sid    = "EcrAuth"
    effect = "Allow"
    actions = [
      "ecr:GetAuthorizationToken"
    ]
    resources = ["*"]
  }

  statement {
    sid    = "EcrPull"
    effect = "Allow"
    actions = [
      "ecr:BatchCheckLayerAvailability",
      "ecr:GetDownloadUrlForLayer",
      "ecr:BatchGetImage"
    ]
    resources = concat(
      [aws_ecr_repository.sync.arn],
      var.additional_ecr_pull_repository_arns,
    )
  }

  statement {
    sid    = "Logs"
    effect = "Allow"
    actions = [
      "logs:CreateLogStream",
      "logs:PutLogEvents"
    ]
    resources = ["${aws_cloudwatch_log_group.sync.arn}:*"]
  }
}

resource "aws_iam_role_policy" "execution" {
  name   = "${var.task_family}-exec-policy"
  role   = aws_iam_role.execution.id
  policy = data.aws_iam_policy_document.execution.json
}

# Task role: the permissions the running container needs.
resource "aws_iam_role" "task" {
  name                 = "${var.task_family}-task-role"
  assume_role_policy   = data.aws_iam_policy_document.ecs_assume.json
  permissions_boundary = var.permissions_boundary_arn
  tags                 = var.tags
}

data "aws_iam_policy_document" "task" {
  statement {
    sid    = "S3Bucket"
    effect = "Allow"
    actions = [
      "s3:ListBucket",
      "s3:GetBucketLocation"
    ]
    resources = [var.s3_bucket_arn]
  }

  statement {
    sid    = "S3Objects"
    effect = "Allow"
    actions = [
      "s3:GetObject",
      "s3:PutObject",
      "s3:DeleteObject",
      # aws s3 sync between S3 locations (staging -> prod promote) copies each
      # object's tags, which requires the tagging read/write pair.
      "s3:GetObjectTagging",
      "s3:PutObjectTagging",
      "s3:ListMultipartUploadParts",
      "s3:AbortMultipartUpload"
    ]
    resources = ["${var.s3_bucket_arn}/*"]
  }

  statement {
    sid    = "S3Kms"
    effect = "Allow"
    actions = [
      "kms:Encrypt",
      "kms:Decrypt",
      "kms:GenerateDataKey"
    ]
    resources = [var.s3_kms_key_arn]
    condition {
      test     = "StringEquals"
      variable = "kms:ViaService"
      values   = ["s3.${var.s3_region}.amazonaws.com"]
    }
  }

  statement {
    sid    = "DynamoDbLock"
    effect = "Allow"
    actions = [
      "dynamodb:GetItem",
      "dynamodb:UpdateItem",
      "dynamodb:PutItem",
      "dynamodb:DeleteItem",
      "dynamodb:Query"
    ]
    resources = [var.dynamodb_table_arn]
  }

  statement {
    sid    = "DynamoDbKms"
    effect = "Allow"
    actions = [
      "kms:Encrypt",
      "kms:Decrypt",
      "kms:GenerateDataKey"
    ]
    resources = [var.dynamodb_kms_key_arn]
    condition {
      test     = "StringEquals"
      variable = "kms:ViaService"
      values   = ["dynamodb.${data.aws_region.current.region}.amazonaws.com"]
    }
  }
}

resource "aws_iam_role_policy" "task" {
  name   = "${var.task_family}-task-policy"
  role   = aws_iam_role.task.id
  policy = data.aws_iam_policy_document.task.json
}

# ---------------------------------------------------------------------------
# 5. Security group
# ---------------------------------------------------------------------------

resource "aws_security_group" "sync" {
  name        = "${var.task_family}-sg"
  description = "Sync engine Fargate tasks. No inbound; outbound HTTPS only."
  vpc_id      = var.vpc_id

  # No ingress rules: the tasks accept no inbound connections.

  # DOCUMENTED EXCEPTION (see SECURITY.md): sole internet-fetching component; upstream OS
  # mirror CDNs (rotating IPs, no stable CIDR) plus cross-region S3 give no honest CIDR to scope. Harden via Network Firewall FQDN allowlist.
  egress {
    description = "HTTPS egress needed to fetch upstream mirrors."
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = var.tags
}
