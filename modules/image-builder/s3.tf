# Pipeline-owned artifact bucket: ships the GPG public keys to the build instance
# (S3Download in the setup component). Mirrors the proven pattern of a small
# per-pipeline config bucket the build role can read; nothing else writes here.

locals {
  gpg_key_files_dir = coalesce(var.gpg_key_files_dir, "${path.module}/files")

  # Every distinct key filename referenced by any baked OS. Uploading by explicit
  # name (not a directory glob) fails the plan early when a referenced file is missing.
  gpg_key_files = distinct(flatten([for os, cfg in var.images : values(cfg.gpg_keys)]))
}

resource "aws_s3_bucket" "artifacts" {
  bucket = "${var.name_prefix}-imagebuilder-${data.aws_caller_identity.current.account_id}"
  tags   = local.common_tags
}

resource "aws_s3_bucket_versioning" "artifacts" {
  bucket = aws_s3_bucket.artifacts.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "artifacts" {
  bucket = aws_s3_bucket.artifacts.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm     = "aws:kms"
      kms_master_key_id = var.component_kms_key_arn
    }
    bucket_key_enabled = true
  }
}

resource "aws_s3_bucket_public_access_block" "artifacts" {
  bucket                  = aws_s3_bucket.artifacts.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_lifecycle_configuration" "artifacts" {
  bucket = aws_s3_bucket.artifacts.id
  rule {
    id     = "abort-incomplete-multipart"
    status = "Enabled"
    filter {}
    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }
  }
}

data "aws_iam_policy_document" "artifacts_bucket" {
  statement {
    sid     = "DenyInsecureTransport"
    effect  = "Deny"
    actions = ["s3:*"]
    resources = [
      aws_s3_bucket.artifacts.arn,
      "${aws_s3_bucket.artifacts.arn}/*",
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
}

resource "aws_s3_bucket_policy" "artifacts" {
  bucket = aws_s3_bucket.artifacts.id
  policy = data.aws_iam_policy_document.artifacts_bucket.json
}

resource "aws_s3_object" "gpg_keys" {
  for_each = toset(local.gpg_key_files)

  bucket      = aws_s3_bucket.artifacts.id
  key         = "configs/${each.value}"
  source      = "${local.gpg_key_files_dir}/${each.value}"
  source_hash = filemd5("${local.gpg_key_files_dir}/${each.value}")
  tags        = local.common_tags
}

# Curated per-OS package lists the bake installs from the frozen mirror.
resource "aws_s3_object" "baked_packages" {
  for_each = { for os, cfg in var.images : os => cfg.baked_packages_file if cfg.baked_packages_file != "" }

  bucket      = aws_s3_bucket.artifacts.id
  key         = "configs/${each.key}-packages.txt"
  source      = each.value
  source_hash = filemd5(each.value)
  tags        = local.common_tags
}

# Optional trust anchor for the mirror's TLS certificate (see var.mirror_ca_cert_file).
resource "aws_s3_object" "mirror_ca" {
  count = var.mirror_ca_cert_file != "" ? 1 : 0

  bucket      = aws_s3_bucket.artifacts.id
  key         = "configs/mirror-ca.crt"
  source      = var.mirror_ca_cert_file
  source_hash = filemd5(var.mirror_ca_cert_file)
  tags        = local.common_tags
}
