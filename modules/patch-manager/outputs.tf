output "baseline_ids" {
  description = "Map of baseline_key to created SSM patch baseline id."
  value       = { for k, b in aws_ssm_patch_baseline.this : k => b.id }
}

output "scan_association_ids" {
  description = "Map of baseline_key to Scan association id. Consume post-apply if an AssociationId must be injected into AWS-RunPatchBaselineAssociation."
  value       = { for k, a in aws_ssm_association.scan : k => a.association_id }
}

output "install_association_ids" {
  description = "Map of baseline_key to Install association id. Consume post-apply if an AssociationId must be injected into AWS-RunPatchBaselineAssociation."
  value       = { for k, a in aws_ssm_association.install : k => a.association_id }
}

output "log_bucket_name" {
  description = "Name of the S3 bucket receiving SSM patch operation logs."
  value       = aws_s3_bucket.logs.id
}
