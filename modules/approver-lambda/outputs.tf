output "function_name" {
  description = "Name of the approver Lambda function"
  value       = aws_lambda_function.approver.function_name
}

output "function_arn" {
  description = "ARN of the approver Lambda function"
  value       = aws_lambda_function.approver.arn
}

output "function_url" {
  description = "HTTPS endpoint of the approver review page (API Gateway HTTP API)"
  value       = aws_apigatewayv2_api.approver.api_endpoint
}

output "role_arn" {
  description = "ARN of the approver Lambda execution role"
  value       = aws_iam_role.approver.arn
}
