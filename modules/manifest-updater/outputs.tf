output "function_name" {
  description = "Name of the manifest updater Lambda function."
  value       = aws_lambda_function.manifest_updater.function_name
}

output "function_arn" {
  description = "ARN of the manifest updater Lambda function."
  value       = aws_lambda_function.manifest_updater.arn
}

output "role_arn" {
  description = "ARN of the IAM role assumed by the Lambda function."
  value       = aws_iam_role.manifest_updater.arn
}
