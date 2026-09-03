# Client-specific and environment inputs for the mirror (read path) module.
# This module runs in the WORKLOAD (air-gapped) account, us-west-2.

variable "vpc_id" {
  description = "VPC ID where the mirror ECS service and internal ALB are deployed."
  type        = string
}

variable "subnet_ids" {
  description = "Private subnet IDs for the internal ALB, ECS tasks, and Route53 target."
  type        = list(string)
}

variable "image_tag" {
  description = "Container image tag to run for the mirror service."
  type        = string
}

variable "mirror_ecr_repo_name" {
  description = "Name of the ECR repository holding the mirror image."
  type        = string
}

variable "ecr_kms_key_arn" {
  description = "Customer-managed KMS key ARN used to encrypt the ECR repository. When null the repository falls back to AES256; supply a key ARN to satisfy KMS-encryption requirements."
  type        = string
  default     = null
}

variable "log_kms_key_arn" {
  description = "Customer-managed KMS key ARN used to encrypt the mirror CloudWatch log group. Supply a key ARN per deployment to satisfy log-encryption requirements; null leaves the group AWS-managed."
  type        = string
  default     = null
}

variable "access_logs_bucket" {
  description = "S3 bucket name for ALB access logs. When set, an access_logs block is enabled on the ALB; supply a bucket per deployment. Null omits the block."
  type        = string
  default     = null
}

variable "task_family" {
  description = "ECS task definition family name."
  type        = string
}

variable "desired_count" {
  description = "Number of ECS tasks to run."
  type        = number
  default     = 3
}

# Cross-account references live in the DISTRIBUTION account.
variable "frozen_bucket_arn" {
  description = "ARN of the frozen S3 bucket in the distribution account (read source)."
  type        = string
}

variable "frozen_bucket_kms_key_arn" {
  description = "ARN of the KMS key encrypting the frozen bucket in the distribution account."
  type        = string
}

variable "frozen_bucket_account_id" {
  description = "AWS account id that owns the cross-account frozen S3 bucket (Distribution account); pins s3 reads to that account."
  type        = string
}

variable "s3_bucket" {
  description = "Name of the frozen S3 bucket the mirror reads from."
  type        = string
}

variable "s3_region" {
  description = "Region of the frozen S3 bucket."
  type        = string
  default     = "us-west-2"
}

# Networking / TLS
variable "acm_certificate_arn" {
  description = "ACM certificate ARN for the internal ALB HTTPS listener."
  type        = string
}

variable "ingress_cidrs" {
  description = "CIDR blocks allowed to reach the internal ALB on 443. Must be explicit ranges (fleet subnets / VPC CIDR); open CIDRs are rejected."
  type        = list(string)

  validation {
    condition = alltrue([
      for c in var.ingress_cidrs : c != "0.0.0.0/0" && c != "::/0"
    ])
    error_message = "ingress_cidrs must not contain 0.0.0.0/0 or ::/0. Scope ingress to the fleet/VPC CIDRs that consume the mirror."
  }
}

# DNS (optional)
variable "mirror_hostname" {
  description = "Fully qualified hostname for the mirror (used for the CNAME and mirror_url output)."
  type        = string
}

variable "private_zone_id" {
  description = "Route53 private hosted zone ID for the CNAME record."
  type        = string
  default     = ""
}

variable "create_dns_record" {
  description = "Whether to create the Route53 CNAME record pointing at the ALB."
  type        = bool
  default     = false
}

# Tagging
variable "tags" {
  description = "Tags applied to all resources."
  type        = map(string)
  default     = {}
}

variable "create_vpc_endpoints" {
  description = "Whether this module creates the S3 gateway endpoint and the KMS/ECR/Logs interface endpoints. Set false when the VPC already provides them: AWS allows only one private-DNS interface endpoint per service per VPC, so duplicates fail at apply. When false, the pre-existing endpoints' security groups must allow 443 from this VPC's CIDR or from the mirror task SG."
  type        = bool
  default     = true
}
