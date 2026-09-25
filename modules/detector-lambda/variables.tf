variable "function_name" {
  description = "Name of the detector Lambda function"
  type        = string
}

variable "s3_region" {
  description = "Region of the frozen-store S3 bucket, used to scope the S3 KMS grant's kms:ViaService (the detector runs in us-east-1 but the bucket/key live in us-west-2)."
  type        = string
  default     = "us-west-2"
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
  description = "ARN of the SNS topic used to send review notifications"
  type        = string
}

variable "sns_kms_key_arn" {
  description = "ARN of the KMS key encrypting the SNS topic"
  type        = string
}

variable "token_kms_key_arn" {
  description = "ARN of the KMS key used to encrypt approval tokens"
  type        = string
}

variable "s3_bucket" {
  description = "Name of the S3 bucket holding manifest and request artifacts"
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

variable "lambda_source_dir" {
  type        = string
  description = "Directory containing the Lambda handler source to zip. Defaults to the module-relative path; Terragrunt passes an absolute get_repo_root()-based path (the module runs from a cache dir where a module-relative climb would not resolve)."
  default     = null
}

variable "apply_lambda_url" {
  description = "Public function URL of the approver Lambda, embedded in review links"
  type        = string
}

variable "token_expiry_hours" {
  description = "Lifetime of an approval token in hours"
  type        = number
  default     = 336
}

variable "upstream_repos" {
  description = "Map of frozen OS -> (component -> upstream URL) the detector diffs against the manifest. Serialized into the Lambda as the UPSTREAM_REPOS env var and iterated as a dict by the handler. Derived from the central os_matrix (config.hcl), so it stays in lockstep with the sync engine's upstream_repos_map."
  type        = map(map(string))
  default = {
    alma810 = {
      baseos    = "https://repo.example.com/almalinux/8.10/BaseOS/x86_64/os/"
      appstream = "https://repo.example.com/almalinux/8.10/AppStream/x86_64/os/"
      epel      = "https://epel.example.com/8/Everything/x86_64/"
    }
  }
}

variable "schedule_expression" {
  description = "EventBridge schedule expression that triggers the detector"
  type        = string
  default     = "cron(0 8 1 * ? *)"
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

variable "env_kms_key_arn" {
  description = "Optional customer-managed KMS key ARN to encrypt Lambda environment variables at rest. Null uses the AWS-managed default key."
  type        = string
  default     = null
}
