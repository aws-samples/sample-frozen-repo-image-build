output "image_pipeline_arns" {
  description = "Map of os_prefix to the Image Builder pipeline ARN for that OS."
  value       = { for os, p in aws_imagebuilder_image_pipeline.this : os => p.arn }
}

output "recipe_arns" {
  description = "Map of os_prefix to the Image Builder recipe ARN for that OS."
  value       = { for os, r in aws_imagebuilder_image_recipe.this : os => r.arn }
}

output "artifact_bucket" {
  description = "Pipeline-owned artifact bucket holding the GPG key objects the bake downloads."
  value       = aws_s3_bucket.artifacts.id
}
