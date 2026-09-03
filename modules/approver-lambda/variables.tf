variable "function_name" {
  description = "Name of the approver Lambda function"
  type        = string
}

variable "subnet_ids" {
  description = "Subnet IDs the Lambda runs in (VPC mode)"
  type        = list(string)
}

variable "security_group_id" {
  description = "Security group ID attached to the Lambda ENI"
  type        = string
}

variable "dynamodb_table_name" {
  description = "Name of the DynamoDB table used to track requests"
  type        = string
}

variable "dynamodb_table_arn" {
  description = "ARN of the DynamoDB table"
  type        = string
}

variable "dynamodb_kms_key_arn" {
  description = "ARN of the KMS key encrypting the DynamoDB table"
  type        = string
}

variable "sns_topic_arn" {
  description = "ARN of the SNS topic used to send notifications"
  type        = string
}

variable "sns_kms_key_arn" {
  description = "ARN of the KMS key encrypting the SNS topic"
  type        = string
}

variable "token_kms_key_arn" {
  description = "ARN of the KMS key used to decrypt approval tokens"
  type        = string
}

variable "s3_bucket" {
  description = "Name of the S3 bucket holding request artifacts"
  type        = string
}

variable "s3_bucket_arn" {
  description = "ARN of the S3 bucket"
  type        = string
}

variable "s3_kms_key_arn" {
  description = "ARN of the KMS key encrypting the S3 bucket"
  type        = string
}

variable "ecs_cluster" {
  description = "Name or ARN of the ECS cluster that runs the sync task"
  type        = string
}

variable "ecs_cluster_arn" {
  description = "ARN of the ECS cluster, used to constrain ecs:RunTask to this cluster via the ecs:cluster condition key."
  type        = string
}

variable "ecs_task_family" {
  description = "ECS task definition family for the sync task"
  type        = string
}

variable "sync_task_definition_arn" {
  description = "ARN of the sync ECS task definition invoked via ecs:RunTask"
  type        = string
}

variable "ecs_subnet_ids" {
  description = "Subnet IDs the sync ECS task launches into"
  type        = list(string)
}

variable "ecs_security_group" {
  description = "Security group ID for the sync ECS task"
  type        = string
}

variable "sync_task_role_arn" {
  description = "ARN of the sync task role passed to ECS via iam:PassRole"
  type        = string
}

variable "sync_exec_role_arn" {
  description = "ARN of the sync execution role passed to ECS via iam:PassRole"
  type        = string
}

variable "permissions_boundary_arn" {
  description = "Optional IAM permissions boundary ARN to attach to the execution role"
  type        = string
  default     = ""
}

variable "reserved_concurrency" {
  description = "Reserved concurrent executions for the Lambda function"
  type        = number
  default     = 5
}

variable "lambda_source_dir" {
  type        = string
  description = "Directory containing the Lambda handler source to zip. Defaults to the module-relative path (works for plain Terraform); Terragrunt passes an absolute get_repo_root()-based path because the module is copied into a cache dir where a module-relative climb would not resolve."
  default     = null
}

variable "env_kms_key_arn" {
  description = "Customer-managed KMS key ARN used to encrypt the Lambda environment variables at rest. Required so env vars are encrypted with a CMK rather than the AWS-managed default key."
  type        = string
}

variable "untrusted_artifact_on_deployment" {
  description = "Lambda code-signing policy for unsigned/untrusted artifacts: 'Warn' (deploy but log, suitable for the unsigned reference zip) or 'Enforce' (hard-reject unsigned code; use once the artifact is signed by the Signer profile)."
  type        = string
  default     = "Warn"

  validation {
    condition     = contains(["Warn", "Enforce"], var.untrusted_artifact_on_deployment)
    error_message = "untrusted_artifact_on_deployment must be either 'Warn' or 'Enforce'."
  }
}

variable "log_kms_key_arn" {
  description = "Customer-managed KMS key ARN used to encrypt the API access-log group. Supply a key ARN per deployment to satisfy log-encryption requirements; null leaves the group AWS-managed."
  type        = string
  default     = null
}
