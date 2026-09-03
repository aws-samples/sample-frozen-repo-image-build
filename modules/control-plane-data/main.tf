# All resources in this module live in the DISTRIBUTION account, us-east-1.
# The caller is expected to configure the aws provider for that account/region.

data "aws_caller_identity" "current" {}
data "aws_partition" "current" {}
data "aws_region" "current" {}

locals {
  account_id = data.aws_caller_identity.current.account_id
  partition  = data.aws_partition.current.partition
  root_arn   = "arn:${data.aws_partition.current.partition}:iam::${data.aws_caller_identity.current.account_id}:root"
}

# ---------------------------------------------------------------------------
# KMS: DynamoDB SSE key
# Grant scoped to control plane roles via aws:PrincipalArn on an account-root
# principal, so it stays valid before the roles exist (KMS validates root at CreateKey).
# ---------------------------------------------------------------------------
resource "aws_kms_key" "dynamodb" {
  description             = "CMK for control plane DynamoDB table SSE"
  enable_key_rotation     = true
  deletion_window_in_days = 30

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "EnableRootAccount"
        Effect    = "Allow"
        Principal = { AWS = local.root_arn }
        Action    = "kms:*"
        Resource  = "*"
      },
      {
        Sid       = "AllowControlPlaneRolesUsage"
        Effect    = "Allow"
        Principal = { AWS = local.root_arn }
        Action = [
          "kms:Encrypt",
          "kms:Decrypt",
          "kms:GenerateDataKey",
          "kms:DescribeKey"
        ]
        Resource = "*"
        Condition = {
          ArnEquals = {
            "aws:PrincipalArn" = var.control_plane_role_arns
          }
        }
      }
    ]
  })

  tags = var.tags
}

resource "aws_kms_alias" "dynamodb" {
  name          = "alias/${var.table_name}-sse"
  target_key_id = aws_kms_key.dynamodb.key_id
}

# ---------------------------------------------------------------------------
# KMS: Token signing key
# SECURITY CORE: split access by design, detector Encrypt-only / approver Decrypt-only,
# so no single role can both mint and validate a token. Enforced in key policy (defence
# in depth); pinned per-role via aws:PrincipalArn on account root (existence-safe). Do NOT collapse.
# ---------------------------------------------------------------------------
resource "aws_kms_key" "token_signing" {
  description             = "CMK for control plane token signing with split encrypt/decrypt access"
  enable_key_rotation     = true
  deletion_window_in_days = 30

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "EnableRootAccount"
        Effect    = "Allow"
        Principal = { AWS = local.root_arn }
        Action    = "kms:*"
        Resource  = "*"
      },
      {
        # Detector: Encrypt-only. Produces tokens, cannot decrypt them.
        Sid       = "DetectorEncryptOnly"
        Effect    = "Allow"
        Principal = { AWS = local.root_arn }
        Action = [
          "kms:Encrypt",
          "kms:GenerateDataKey",
          "kms:DescribeKey"
        ]
        Resource = "*"
        Condition = {
          ArnEquals = {
            "aws:PrincipalArn" = var.detector_role_arn
          }
        }
      },
      {
        # Approver: Decrypt-only. Consumes tokens, cannot mint them.
        Sid       = "ApproverDecryptOnly"
        Effect    = "Allow"
        Principal = { AWS = local.root_arn }
        Action = [
          "kms:Decrypt",
          "kms:DescribeKey"
        ]
        Resource = "*"
        Condition = {
          ArnEquals = {
            "aws:PrincipalArn" = var.approver_role_arn
          }
        }
      }
    ]
  })

  tags = var.tags
}

resource "aws_kms_alias" "token_signing" {
  name          = "alias/${var.table_name}-token-signing"
  target_key_id = aws_kms_key.token_signing.key_id
}

# ---------------------------------------------------------------------------
# KMS: SNS key
# Lets SNS decrypt/generate data keys to deliver encrypted messages; control plane roles publish.
# ---------------------------------------------------------------------------
resource "aws_kms_key" "sns" {
  description             = "CMK for control plane SNS topic encryption"
  enable_key_rotation     = true
  deletion_window_in_days = 30

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "EnableRootAccount"
        Effect    = "Allow"
        Principal = { AWS = local.root_arn }
        Action    = "kms:*"
        Resource  = "*"
      },
      {
        # SNS service needs these to encrypt messages at rest and deliver them.
        Sid       = "AllowSNSServiceUsage"
        Effect    = "Allow"
        Principal = { Service = "sns.amazonaws.com" }
        Action = [
          "kms:Decrypt",
          "kms:GenerateDataKey"
        ]
        Resource = "*"
        Condition = {
          StringEquals = {
            "kms:ViaService" = "sns.${data.aws_region.current.region}.amazonaws.com"
          }
        }
      },
      {
        # Control plane roles publish to the topic; scoped via aws:PrincipalArn
        # on account root (existence-safe: validates at CreateKey, condition gates at use).
        Sid       = "AllowControlPlaneRolesPublish"
        Effect    = "Allow"
        Principal = { AWS = local.root_arn }
        Action = [
          "kms:Encrypt",
          "kms:Decrypt",
          "kms:GenerateDataKey",
          "kms:DescribeKey"
        ]
        Resource = "*"
        Condition = {
          ArnEquals = {
            "aws:PrincipalArn" = var.control_plane_role_arns
          }
        }
      }
    ]
  })

  tags = var.tags
}

resource "aws_kms_alias" "sns" {
  name          = "alias/${var.topic_name}-sns"
  target_key_id = aws_kms_key.sns.key_id
}

# ---------------------------------------------------------------------------
# DynamoDB table
# ---------------------------------------------------------------------------
resource "aws_dynamodb_table" "control_plane" {
  name         = var.table_name
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "request_id"

  attribute {
    name = "request_id"
    type = "S"
  }

  ttl {
    attribute_name = "expires_at"
    enabled        = true
  }

  point_in_time_recovery {
    enabled = true
  }

  server_side_encryption {
    enabled     = true
    kms_key_arn = aws_kms_key.dynamodb.arn
  }

  deletion_protection_enabled = true

  tags = var.tags
}

# ---------------------------------------------------------------------------
# SNS topic and approval email subscription
# ---------------------------------------------------------------------------
resource "aws_sns_topic" "approval" {
  name              = var.topic_name
  kms_master_key_id = aws_kms_key.sns.arn

  tags = var.tags
}

resource "aws_sns_topic_subscription" "approval_email" {
  topic_arn = aws_sns_topic.approval.arn
  protocol  = "email"
  endpoint  = var.approval_email
}
