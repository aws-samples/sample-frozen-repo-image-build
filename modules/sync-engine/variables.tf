# Sync Engine module - input variables
# DISTRIBUTION account, us-east-1. No client identifiers are hardcoded.

variable "log_retention_days" {
  description = "CloudWatch log group retention in days. Defaults to 365 to satisfy the minimum-one-year retention requirement."
  type        = number
  default     = 365
}

variable "ecr_kms_key_arn" {
  description = "Customer-managed KMS key ARN used to encrypt the ECR repository. When null the repository falls back to AES256; supply a key ARN to satisfy KMS-encryption requirements."
  type        = string
  default     = null
}

variable "log_kms_key_arn" {
  description = "Customer-managed KMS key ARN used to encrypt the sync CloudWatch log group. Supply a key ARN per deployment to satisfy log-encryption requirements; null leaves the group AWS-managed."
  type        = string
  default     = null
}

variable "ecr_repo_name" {
  description = "Name of the ECR repository for the sync container image."
  type        = string
}

variable "image_tag" {
  description = "Image tag used by the task definition container."
  type        = string
  default     = "latest"
}

variable "task_family" {
  description = "ECS task definition family name."
  type        = string
}

variable "s3_region" {
  description = "Region of the target S3 bucket."
  type        = string
  default     = "us-west-2"
}

variable "s3_bucket" {
  description = "Name of the S3 bucket the sync engine reads and writes."
  type        = string
}

variable "s3_bucket_arn" {
  description = "ARN of the S3 bucket (used for bucket-level IAM permissions)."
  type        = string
}

variable "dynamodb_table" {
  description = "Name of the DynamoDB table used for the sync lock."
  type        = string
}

variable "dynamodb_table_arn" {
  description = "ARN of the DynamoDB table used for the sync lock."
  type        = string
}

variable "dynamodb_region" {
  description = "Region of the DynamoDB table."
  type        = string
  default     = "us-east-1"
}

variable "s3_kms_key_arn" {
  description = "ARN of the KMS key protecting the S3 bucket."
  type        = string
}

variable "dynamodb_kms_key_arn" {
  description = "ARN of the KMS key protecting the DynamoDB table."
  type        = string
}

variable "permissions_boundary_arn" {
  description = "Optional IAM permissions boundary ARN attached to the execution and task roles."
  type        = string
  default     = null
}

variable "vpc_id" {
  description = "VPC in which the sync engine security group is created."
  type        = string
}

variable "subnet_ids" {
  description = "Subnet IDs available to run the Fargate tasks."
  type        = list(string)
}

variable "upstream_repos_map" {
  description = "Map of upstream mirror sources, serialized into the container as UPSTREAM_REPOS_MAP."
  type        = map(map(string))
  default = {
    rhel810 = {
      baseos    = "https://repo.example.com/8.10/BaseOS/x86_64/os/"
      appstream = "https://repo.example.com/8.10/AppStream/x86_64/os/"
      epel      = "https://epel.example.com/8/Everything/x86_64/"
    }
  }
}

variable "tags" {
  description = "Tags applied to all resources that support tagging."
  type        = map(string)
  default     = {}
}
