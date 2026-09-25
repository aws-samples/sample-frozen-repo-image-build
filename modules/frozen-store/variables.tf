# -----------------------------------------------------------------------------
# frozen-store module: input variables (all client-specific values supplied here).
# -----------------------------------------------------------------------------

variable "bucket_name" {
  description = "Name of the frozen store S3 bucket (must be globally unique)."
  type        = string
}

variable "mirror_task_role_arn" {
  description = "ARN of the workload-account mirror task role granted cross-account read (S3 and KMS Decrypt/DescribeKey)."
  type        = string
}

variable "writer_role_arns" {
  description = "ARNs of local writer roles (sync task, lambdas, imagebuilder) granted KMS Encrypt/Decrypt."
  type        = list(string)
}

variable "repo_matrix" {
  description = "Map of os_prefix to a list of repo_id values. A Packages/ and repodata/ folder skeleton is created per os/repo pair."
  type        = map(list(string))

  default = {
    alma810 = ["baseos", "appstream", "epel"]
  }
}

variable "force_destroy" {
  description = "Whether Terraform may delete all object versions and delete markers when destroying the frozen store. Keep false during normal operation."
  type        = bool
  default     = false
}

variable "tags" {
  description = "Tags applied to the KMS key and S3 bucket."
  type        = map(string)
  default     = {}
}
