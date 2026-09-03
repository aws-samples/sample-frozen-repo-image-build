# -----------------------------------------------------------------------------
# frozen-store module: KMS-encrypted versioned S3 bucket (DISTRIBUTION, us-west-2)
# holding mirrored repos; cross-account read to workload mirror role, write to local writer roles.
# -----------------------------------------------------------------------------

data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

locals {
  account_id = data.aws_caller_identity.current.account_id

  # Account roots as named principals; access scoped to exact role ARNs via
  # aws:PrincipalArn (least privilege, valid before roles exist as KMS validates principal at CreateKey).
  dist_root_arn = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:root"
  # Workload account root, derived from the cross-account mirror role ARN.
  workload_root_arn = "arn:aws:iam::${split(":", var.mirror_task_role_arn)[4]}:root"

  # Flatten repo_matrix (os_prefix -> [repo_id, ...]) into "<os>/<repo>" pairs.
  os_repo_pairs = flatten([
    for os_prefix, repo_ids in var.repo_matrix : [
      for repo_id in repo_ids : {
        key  = "${os_prefix}/${repo_id}"
        os   = os_prefix
        repo = repo_id
      }
    ]
  ])

  # Two skeleton keys per os/repo: Packages/ and repodata/.
  folder_keys = merge([
    for pair in local.os_repo_pairs : {
      "${pair.key}/Packages" = "${pair.key}/Packages/"
      "${pair.key}/repodata" = "${pair.key}/repodata/"
    }
  ]...)
}

# -----------------------------------------------------------------------------
# KMS key
# -----------------------------------------------------------------------------

data "aws_iam_policy_document" "kms" {
  #checkov:skip=CKV_AWS_109:KMS key policy Resource=* refers to the key itself, per AWS key-policy semantics
  #checkov:skip=CKV_AWS_111:KMS key policy Resource=* refers to the key itself, per AWS key-policy semantics
  #checkov:skip=CKV_AWS_356:KMS key policy Resource=* refers to the key itself, per AWS key-policy semantics
  # Root of the caller account retains full control (IAM management path).
  statement {
    sid       = "EnableRootAccountAdmin"
    effect    = "Allow"
    actions   = ["kms:*"]
    resources = ["*"]

    principals {
      type        = "AWS"
      identifiers = ["arn:aws:iam::${local.account_id}:root"]
    }
  }

  # S3 service use, scoped to this account via encryption context.
  statement {
    sid    = "AllowS3ServiceUse"
    effect = "Allow"

    actions = [
      "kms:Decrypt",
      "kms:GenerateDataKey",
      "kms:DescribeKey",
    ]

    resources = ["*"]

    principals {
      type        = "Service"
      identifiers = ["s3.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [local.account_id]
    }

    condition {
      test     = "StringEquals"
      variable = "kms:ViaService"
      values   = ["s3.${data.aws_region.current.region}.amazonaws.com"]
    }
  }

  # Cross-account mirror role (workload account), read path only. Principal is workload
  # account root, pinned to the exact mirror role ARN via aws:PrincipalArn (existence-safe).
  statement {
    sid    = "AllowMirrorRoleDecrypt"
    effect = "Allow"

    actions = [
      "kms:Decrypt",
      "kms:DescribeKey",
    ]

    resources = ["*"]

    principals {
      type        = "AWS"
      identifiers = [local.workload_root_arn]
    }

    condition {
      test     = "ArnEquals"
      variable = "aws:PrincipalArn"
      values   = [var.mirror_task_role_arn]
    }
  }

  # Local writer roles (sync task, lambdas, imagebuilder), read and write. Principal is
  # dist account root, pinned to exact writer role ARNs via aws:PrincipalArn (existence-safe).
  statement {
    sid    = "AllowWriterRolesEncryptDecrypt"
    effect = "Allow"

    actions = [
      "kms:Encrypt",
      "kms:Decrypt",
      "kms:ReEncrypt*",
      "kms:GenerateDataKey*",
      "kms:DescribeKey",
    ]

    resources = ["*"]

    principals {
      type        = "AWS"
      identifiers = [local.dist_root_arn]
    }

    condition {
      test     = "ArnEquals"
      variable = "aws:PrincipalArn"
      values   = var.writer_role_arns
    }
  }
}

resource "aws_kms_key" "frozen_store" {
  description             = "SSE-KMS key for the frozen store S3 bucket (${var.bucket_name})"
  deletion_window_in_days = 30
  enable_key_rotation     = true
  policy                  = data.aws_iam_policy_document.kms.json

  tags = var.tags
}

resource "aws_kms_alias" "frozen_store" {
  name          = "alias/${var.bucket_name}"
  target_key_id = aws_kms_key.frozen_store.key_id
}

# -----------------------------------------------------------------------------
# S3 bucket
# -----------------------------------------------------------------------------

resource "aws_s3_bucket" "frozen_store" {
  bucket = var.bucket_name
  tags   = var.tags
}

resource "aws_s3_bucket_versioning" "frozen_store" {
  bucket = aws_s3_bucket.frozen_store.id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "frozen_store" {
  bucket = aws_s3_bucket.frozen_store.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm     = "aws:kms"
      kms_master_key_id = aws_kms_key.frozen_store.arn
    }

    bucket_key_enabled = true
  }
}

resource "aws_s3_bucket_public_access_block" "frozen_store" {
  bucket = aws_s3_bucket.frozen_store.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_lifecycle_configuration" "frozen_store" {
  bucket = aws_s3_bucket.frozen_store.id

  # Depend on versioning so the config applies to a versioned bucket.
  depends_on = [aws_s3_bucket_versioning.frozen_store]

  rule {
    id     = "intelligent-tiering-all-objects"
    status = "Enabled"

    # Apply to every object larger than a single byte (skips the zero-byte
    # folder skeleton markers, which do not benefit from tiering).
    filter {
      object_size_greater_than = 1
    }

    transition {
      days          = 0
      storage_class = "INTELLIGENT_TIERING"
    }
  }

  # Reclaim storage from multipart uploads that never completed. A 7-day
  # window covers large repo-object uploads while satisfying CKV_AWS_300.
  rule {
    id     = "abort-incomplete-multipart-uploads"
    status = "Enabled"

    filter {}

    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }
  }
}

# -----------------------------------------------------------------------------
# Bucket policy: deny non-TLS, allow cross-account read to the mirror role.
# -----------------------------------------------------------------------------

data "aws_iam_policy_document" "bucket" {
  statement {
    sid     = "DenyInsecureTransport"
    effect  = "Deny"
    actions = ["s3:*"]

    resources = [
      aws_s3_bucket.frozen_store.arn,
      "${aws_s3_bucket.frozen_store.arn}/*",
    ]

    principals {
      type        = "AWS"
      identifiers = ["*"]
    }

    condition {
      test     = "Bool"
      variable = "aws:SecureTransport"
      values   = ["false"]
    }
  }

  statement {
    sid    = "AllowMirrorRoleRead"
    effect = "Allow"

    actions = [
      "s3:GetObject",
      "s3:GetObjectVersion",
      "s3:ListBucket",
    ]

    resources = [
      aws_s3_bucket.frozen_store.arn,
      "${aws_s3_bucket.frozen_store.arn}/*",
    ]

    # Workload account root as principal; pinned to the exact mirror role ARN
    # via aws:PrincipalArn so access is scoped to that one role.
    principals {
      type        = "AWS"
      identifiers = [local.workload_root_arn]
    }

    condition {
      test     = "ArnEquals"
      variable = "aws:PrincipalArn"
      values   = [var.mirror_task_role_arn]
    }
  }
}

resource "aws_s3_bucket_policy" "frozen_store" {
  bucket = aws_s3_bucket.frozen_store.id
  policy = data.aws_iam_policy_document.bucket.json

  # Public access block must be in place before attaching a policy.
  depends_on = [aws_s3_bucket_public_access_block.frozen_store]
}

# -----------------------------------------------------------------------------
# Repo folder skeleton: zero-byte keys for Packages/ and repodata/ per os/repo.
# -----------------------------------------------------------------------------

resource "aws_s3_object" "folder_skeleton" {
  for_each = local.folder_keys

  bucket  = aws_s3_bucket.frozen_store.id
  key     = each.value
  content = ""

  # Inherit bucket SSE-KMS default; be explicit so plans are stable.
  server_side_encryption = "aws:kms"
  kms_key_id             = aws_kms_key.frozen_store.arn

  depends_on = [aws_s3_bucket_server_side_encryption_configuration.frozen_store]
}
