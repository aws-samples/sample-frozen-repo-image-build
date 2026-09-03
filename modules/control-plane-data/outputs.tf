output "dynamodb_table_name" {
  description = "Name of the control plane DynamoDB table."
  value       = aws_dynamodb_table.control_plane.name
}

output "dynamodb_table_arn" {
  description = "ARN of the control plane DynamoDB table."
  value       = aws_dynamodb_table.control_plane.arn
}

output "dynamodb_kms_key_arn" {
  description = "ARN of the CMK used for DynamoDB SSE."
  value       = aws_kms_key.dynamodb.arn
}

output "token_signing_key_arn" {
  description = "ARN of the split-access token signing CMK."
  value       = aws_kms_key.token_signing.arn
}

output "sns_topic_arn" {
  description = "ARN of the approval SNS topic."
  value       = aws_sns_topic.approval.arn
}

output "sns_kms_key_arn" {
  description = "ARN of the CMK used for SNS encryption."
  value       = aws_kms_key.sns.arn
}
