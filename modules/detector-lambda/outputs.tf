output "function_name" {
  description = "Name of the detector Lambda function"
  value       = aws_lambda_function.detector.function_name
}

output "function_arn" {
  description = "ARN of the detector Lambda function"
  value       = aws_lambda_function.detector.arn
}

output "role_arn" {
  description = "ARN of the detector Lambda execution role"
  value       = aws_iam_role.detector.arn
}
