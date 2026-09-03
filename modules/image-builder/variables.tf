# EC2 Image Builder module variables (bake from frozen mirror)

variable "name_prefix" {
  description = "Prefix applied to created resource names and tags."
  type        = string
  default     = "frozen-image"
}

variable "frozen_repo_url" {
  description = "Base URL of the frozen package mirror the baked images point at."
  type        = string
}

variable "frozen_bucket_arn" {
  description = "Optional ARN of the frozen-store S3 bucket. When set, the build instance is granted scoped s3:GetObject/ListBucket on that bucket only. When null (default), no direct S3 grant is created (the build pulls packages over HTTPS from the mirror)."
  type        = string
  default     = null
}

variable "images" {
  description = <<-EOT
    Map of OS builds to produce, keyed by os_prefix (for example rhel810). One
    Image Builder pipeline (component set, recipe, infra, distribution) is
    created per entry. Each value:
      parent_image : parent image ARN or AMI id the recipe builds from.
      repos        : component name -> upstream URL (from os_matrix). Only the
                     KEYS are used here: they name the frozen mirror paths
                     (<frozen_repo_url>/<os_prefix>/<component>/) and the baked
                     repo sections, mirroring the S3 layout the sync produces.
      gpg_keys     : component name -> GPG key filename. Each distinct filename
                     must exist in gpg_key_files_dir; it is uploaded to the
                     artifact bucket, imported on the build instance, and
                     referenced by that component's gpgkey= line.
      baked_packages_file : optional path to a curated package list (one
                     name[.arch] per line, comments allowed). When set, the
                     bake installs every listed package FROM the frozen mirror,
                     so the AMI content is frozen-repo-sourced and every build
                     moves real RPMs through the mirror. Use the same file the
                     sync container validates (containers/sync/pkg-lists/) to
                     keep one source of truth. Empty (default) skips the step.
  EOT
  type = map(object({
    parent_image        = string
    repos               = map(string)
    gpg_keys            = map(string)
    baked_packages_file = optional(string, "")
  }))
}

variable "mirror_ca_cert_file" {
  description = "Optional path to a PEM certificate (or CA chain) the build instance must trust to reach the mirror over HTTPS. Empty (default) assumes the parent AMI already trusts the mirror certificate's CA, which is the production posture (private CA root baked upstream). Set it when the parent does not carry the trust anchor, for example a self-signed sandbox certificate: the bake uploads it via the artifact bucket, installs it with update-ca-trust BEFORE any dnf call, and the anchor is baked into the AMI so runtime dnf and SSM patching verify TLS too."
  type        = string
  default     = ""
}

variable "gpg_key_files_dir" {
  description = "Directory holding the GPG public key files named by images[*].gpg_keys. Defaults to the module's bundled files/ (AlmaLinux 8 + EPEL-8 keys matching the shipped os_matrix). Files here are uploaded to the artifact bucket and imported on the build instance before any dnf call."
  type        = string
  default     = null
}

variable "root_volume_size_gb" {
  description = "Root EBS volume size in GiB for the recipe block device mapping."
  type        = number
  default     = 50
}

variable "extra_component_arns" {
  description = "Optional additional Image Builder component ARNs appended after the frozen-repo components."
  type        = list(string)
  default     = []
}

variable "build_instance_types" {
  description = "Instance types Image Builder may use for build/test."
  type        = list(string)
  default     = ["t3.medium"]
}

variable "subnet_id" {
  description = "Subnet id for the build instance."
  type        = string
}

variable "security_group_ids" {
  description = "Security group ids for the build instance."
  type        = list(string)
}

variable "permissions_boundary_arn" {
  description = "IAM permissions boundary ARN attached to the created instance role."
  type        = string
  default     = null
}

variable "distribution_regions" {
  description = "Regions to distribute the built AMI to. One distribution per region."
  type        = list(string)
  default     = ["us-west-2"]
}

variable "region_kms_key_arns" {
  description = "Map of region -> KMS key ARN used to encrypt the distributed AMI in that region."
  type        = map(string)
  default     = {}
}

variable "ebs_kms_key_arn" {
  description = "Customer-managed KMS key ARN used to encrypt the recipe root EBS volume in the build region. When null the build-region default EBS key is used."
  type        = string
  default     = null
}

variable "component_kms_key_arn" {
  description = "Customer-managed KMS key ARN used to encrypt the Image Builder component data. Required so components are encrypted with a CMK rather than the AWS-owned default key."
  type        = string
}

variable "target_account_ids" {
  description = "Account ids granted launch permission on the distributed AMIs."
  type        = list(string)
  default     = []
}

variable "instance_profile_extra_policy_arns" {
  description = "Optional extra managed policy ARNs to attach to the build instance role."
  type        = list(string)
  default     = []
}

variable "tags" {
  description = "Additional tags applied to all resources."
  type        = map(string)
  default     = {}
}

variable "recipe_version" {
  description = "Semantic version for the image recipes. Recipes are immutable: bump this whenever recipe contents (components, block devices, parent image) change, so create_before_destroy can create the new version before deleting the old."
  type        = string
  default     = "1.0.3"
}
