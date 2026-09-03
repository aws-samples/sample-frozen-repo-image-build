variable "table_name" {
  description = "Name of the control plane DynamoDB table."
  type        = string
}

variable "topic_name" {
  description = "Name of the SNS topic for approval notifications."
  type        = string
}

variable "approval_email" {
  description = "Email address subscribed to the approval SNS topic."
  type        = string
}

variable "detector_role_arn" {
  description = "IAM role ARN allowed to Encrypt (only) with the token signing key. This is the producer side of the split-access model."
  type        = string
}

variable "approver_role_arn" {
  description = "IAM role ARN allowed to Decrypt (only) with the token signing key. This is the consumer side of the split-access model."
  type        = string
}

variable "control_plane_role_arns" {
  description = "List of control plane IAM role ARNs granted DynamoDB SSE key usage and SNS publish/key access."
  type        = list(string)
}

variable "tags" {
  description = "Tags applied to all resources."
  type        = map(string)
  default     = {}
}
