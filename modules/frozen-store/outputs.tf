# -----------------------------------------------------------------------------
# frozen-store module: outputs
# -----------------------------------------------------------------------------

output "bucket_name" {
  description = "Name of the frozen store S3 bucket."
  value       = aws_s3_bucket.frozen_store.id
}

output "bucket_arn" {
  description = "ARN of the frozen store S3 bucket."
  value       = aws_s3_bucket.frozen_store.arn
}

output "bucket_regional_domain_name" {
  description = "Regional domain name of the frozen store S3 bucket."
  value       = aws_s3_bucket.frozen_store.bucket_regional_domain_name
}

output "kms_key_arn" {
  description = "ARN of the KMS key encrypting the frozen store bucket."
  value       = aws_kms_key.frozen_store.arn
}
