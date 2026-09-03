variable "function_name" {
  description = "Name of the manifest updater Lambda function."
  type        = string
}

variable "subnet_ids" {
  description = "Subnet IDs the Lambda is attached to (in-VPC)."
  type        = list(string)
}

variable "security_group_id" {
  description = "Security group ID for the Lambda's VPC configuration."
  type        = string
}

variable "s3_bucket" {
  description = "S3 bucket holding the repository manifest and repodata."
  type        = string
}

variable "s3_region" {
  description = "Region of the S3 bucket."
  type        = string
  default     = "us-west-2"
}

variable "s3_kms_key_arn" {
  description = "KMS key ARN used to encrypt/decrypt S3 objects."
  type        = string
}

variable "permissions_boundary_arn" {
  description = "Optional IAM permissions boundary ARN to attach to the Lambda role."
  type        = string
  default     = null
}

variable "sync_cluster_arn" {
  description = "ARN of the ECS cluster whose task state changes trigger the updater."
  type        = string
}

variable "sync_task_definition_arn_prefix" {
  description = "Prefix match for the ECS task definition ARN that triggers the updater."
  type        = string
}

variable "tags" {
  description = "Tags applied to created resources."
  type        = map(string)
  default     = {}
}

variable "reserved_concurrency" {
  description = "Reserved concurrent executions for the Lambda function."
  type        = number
  default     = 5
}

variable "lambda_source_dir" {
  type        = string
  description = "Directory containing the Lambda handler source to zip. Defaults to the module-relative path; Terragrunt passes an absolute get_repo_root()-based path (the module runs from a cache dir where a module-relative climb would not resolve)."
  default     = null
}

variable "env_kms_key_arn" {
  description = "Optional customer-managed KMS key ARN to encrypt Lambda environment variables at rest. Null uses the AWS-managed default key."
  type        = string
  default     = null
}

variable "repo_matrix" {
  description = "Map of os_prefix -> list of component/repo ids to rescan when rebuilding manifest.json (derive from the os_matrix registry: { for os, v in os_matrix : os => keys(v.repos) }). Injected as the REPOS_TO_SCAN env var so this consumer cannot drift from the frozen-store layout."
  type        = map(list(string))
}
