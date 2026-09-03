# Patch Manager module (WORKLOAD air-gapped account, us-west-2). Per var.baselines:
# an SSM patch baseline pointing at the frozen mirror, a patch group, scan+install
# associations, plus one KMS-encrypted S3 bucket for patch logs.
#
# Associations use the standard AWS-RunPatchBaseline document: the -Association
# variant needs a self-referencing AssociationId Terraform cannot know at plan time.

data "aws_caller_identity" "current" {}
data "aws_region" "current" {}
data "aws_partition" "current" {}

locals {
  common_tags = merge(
    {
      Module    = "patch-manager"
      ManagedBy = "terraform"
    },
    var.tags,
  )

  # One SSM patch source per repo component: SSM permits exactly ONE yum repo
  # section per source configuration blob, so each component becomes its own block.
  baseline_sources = {
    for k, b in var.baselines : k => [
      for s in b.sources : {
        name     = s.name
        products = [s.product]
        configuration = join("\n", [
          "[${s.name}]",
          "name=${s.name}",
          "baseurl=${var.mirror_url}/${s.baseurl_path}/",
          "enabled=1",
          "gpgcheck=1",
          "gpgkey=file:///etc/pki/rpm-gpg/${s.gpgkey_file}",
        ])
      }
    ]
  }

  # Distinct products per baseline for the patch source "products" attribute.
  baseline_products = {
    for k, b in var.baselines : k => distinct([for s in b.sources : s.product])
  }
}

#########################
# KMS key for log bucket
#########################

# Explicit scoped key policy (omitting one falls back to kms:* to root): admin to the
# deploy role, usage only to S3 (SSE-KMS on the log bucket) and SSM instances writing logs.
data "aws_iam_policy_document" "logs_kms" {
  count = var.kms_key_arn == null ? 1 : 0

  # Root retains full control (IAM management path). Naming a deploy role directly
  # fails CreateKey when it does not exist and trips the KMS lockout check.
  statement {
    sid       = "EnableRootAccountAdmin"
    effect    = "Allow"
    actions   = ["kms:*"]
    resources = ["*"]
    principals {
      type        = "AWS"
      identifiers = ["arn:${data.aws_partition.current.partition}:iam::${data.aws_caller_identity.current.account_id}:root"]
    }
  }

  # S3 uses the key to encrypt/decrypt log-bucket objects, constrained to this
  # account and to calls made through S3 in this Region.
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
      values   = [data.aws_caller_identity.current.account_id]
    }
    condition {
      test     = "StringEquals"
      variable = "kms:ViaService"
      values   = ["s3.${data.aws_region.current.region}.amazonaws.com"]
    }
  }

  # SSM-managed instances in this account write patch logs to the bucket via S3,
  # so principals in this account may use the key through S3 only.
  statement {
    sid    = "AllowAccountUseViaS3"
    effect = "Allow"
    actions = [
      "kms:Decrypt",
      "kms:GenerateDataKey",
    ]
    resources = ["*"]
    principals {
      type        = "AWS"
      identifiers = ["arn:${data.aws_partition.current.partition}:iam::${data.aws_caller_identity.current.account_id}:root"]
    }
    condition {
      test     = "StringEquals"
      variable = "kms:ViaService"
      values   = ["s3.${data.aws_region.current.region}.amazonaws.com"]
    }
  }
}

resource "aws_kms_key" "logs" {
  count                   = var.kms_key_arn == null ? 1 : 0
  description             = "${var.name_prefix} SSM patch log bucket encryption"
  enable_key_rotation     = true
  deletion_window_in_days = 7
  policy                  = data.aws_iam_policy_document.logs_kms[0].json
  tags                    = local.common_tags
}

resource "aws_kms_alias" "logs" {
  count         = var.kms_key_arn == null ? 1 : 0
  name          = "alias/${var.name_prefix}-patch-logs"
  target_key_id = aws_kms_key.logs[0].key_id
}

locals {
  log_bucket_kms_arn = var.kms_key_arn != null ? var.kms_key_arn : aws_kms_key.logs[0].arn
}

#########################
# S3 log bucket
#########################

resource "aws_s3_bucket" "logs" {
  bucket = "${var.name_prefix}-ssm-patch-logs-${data.aws_caller_identity.current.account_id}"
  tags   = local.common_tags
}

resource "aws_s3_bucket_public_access_block" "logs" {
  bucket                  = aws_s3_bucket.logs.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# Versioning intentionally left disabled per requirements.
resource "aws_s3_bucket_versioning" "logs" {
  bucket = aws_s3_bucket.logs.id
  versioning_configuration {
    status = "Disabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "logs" {
  bucket = aws_s3_bucket.logs.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm     = "aws:kms"
      kms_master_key_id = local.log_bucket_kms_arn
    }
    bucket_key_enabled = true
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "logs" {
  bucket = aws_s3_bucket.logs.id
  rule {
    id     = "expire-patch-logs"
    status = "Enabled"
    filter {
      prefix = "ssm-patch-logs/"
    }
    expiration {
      days = 90
    }
  }

  rule {
    id     = "abort-incomplete-multipart-uploads"
    status = "Enabled"
    filter {}
    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }
  }
}

data "aws_iam_policy_document" "logs_bucket" {
  # Deny any request not using TLS.
  statement {
    sid     = "DenyInsecureTransport"
    effect  = "Deny"
    actions = ["s3:*"]
    resources = [
      aws_s3_bucket.logs.arn,
      "${aws_s3_bucket.logs.arn}/*",
    ]
    principals {
      type        = "*"
      identifiers = ["*"]
    }
    condition {
      test     = "Bool"
      variable = "aws:SecureTransport"
      values   = ["false"]
    }
  }

  # Allow SSM to write patch logs, scoped to this account's principals.
  statement {
    sid       = "AllowSSMPutObject"
    effect    = "Allow"
    actions   = ["s3:PutObject"]
    resources = ["${aws_s3_bucket.logs.arn}/ssm-patch-logs/*"]
    principals {
      type        = "Service"
      identifiers = ["ssm.amazonaws.com"]
    }
    condition {
      test     = "StringEquals"
      variable = "aws:PrincipalAccount"
      values   = [data.aws_caller_identity.current.account_id]
    }
  }
}

resource "aws_s3_bucket_policy" "logs" {
  bucket = aws_s3_bucket.logs.id
  policy = data.aws_iam_policy_document.logs_bucket.json
}

#########################
# Patch baselines
#########################

resource "aws_ssm_patch_baseline" "this" {
  for_each = var.baselines

  name             = "${var.name_prefix}-${each.key}"
  description      = "Frozen-mirror patch baseline for ${each.key}"
  operating_system = each.value.operating_system
  tags             = local.common_tags

  # Global filter: apply to all products in this baseline.
  global_filter {
    key    = "PRODUCT"
    values = local.baseline_products[each.key]
  }

  approval_rule {
    approve_after_days  = var.approve_after_days
    compliance_level    = "UNSPECIFIED"
    enable_non_security = true

    patch_filter {
      key    = "PRODUCT"
      values = local.baseline_products[each.key]
    }
  }

  # One source block per repo component (SSM permits one repository per source).
  dynamic "source" {
    for_each = local.baseline_sources[each.key]
    content {
      name          = source.value.name
      products      = source.value.products
      configuration = source.value.configuration
    }
  }
}

resource "aws_ssm_patch_group" "this" {
  for_each = var.baselines

  baseline_id = aws_ssm_patch_baseline.this[each.key].id
  patch_group = each.value.patch_group
}

#########################
# Associations (scan + install)
#########################

resource "aws_ssm_association" "scan" {
  for_each = var.baselines

  association_name    = "${var.name_prefix}-${each.key}-scan"
  name                = "AWS-RunPatchBaseline"
  schedule_expression = var.scan_schedule

  parameters = {
    Operation = "Scan"
  }

  targets {
    key    = "tag:Patch Group"
    values = [each.value.patch_group]
  }

  output_location {
    s3_bucket_name = aws_s3_bucket.logs.id
    s3_key_prefix  = "ssm-patch-logs/${each.key}/scan/"
  }

  depends_on = [aws_ssm_patch_group.this]
}

resource "aws_ssm_association" "install" {
  for_each = var.baselines

  association_name    = "${var.name_prefix}-${each.key}-install"
  name                = "AWS-RunPatchBaseline"
  schedule_expression = var.install_schedule

  parameters = {
    Operation    = "Install"
    RebootOption = "RebootIfNeeded"
  }

  targets {
    key    = "tag:Patch Group"
    values = [each.value.patch_group]
  }

  output_location {
    s3_bucket_name = aws_s3_bucket.logs.id
    s3_key_prefix  = "ssm-patch-logs/${each.key}/install/"
  }

  depends_on = [aws_ssm_patch_group.this]
}
