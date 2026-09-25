# Patch Manager module variables (WORKLOAD / air-gapped account)

variable "name_prefix" {
  description = "Prefix applied to created resource names and tags."
  type        = string
  default     = "frozen-patch"
}

variable "mirror_url" {
  description = "Base URL of the internal frozen package mirror reachable from the air-gapped account. baseurl_path values in var.baselines are appended to this."
  type        = string
}

variable "approve_after_days" {
  description = "Number of days to wait before auto-approving patches in each baseline approval rule. 0 approves immediately."
  type        = number
  default     = 0
}

variable "scan_schedule" {
  description = "Cron/rate expression for the AWS-RunPatchBaseline Scan association."
  type        = string
  default     = "cron(0 22 ? * SAT *)"
}

variable "install_schedule" {
  description = "Cron/rate expression for the AWS-RunPatchBaseline Install association."
  type        = string
  default     = "cron(0 2 ? * SUN *)"
}

variable "kms_key_arn" {
  description = "Optional KMS key ARN for the log bucket. When null a new key is created by this module."
  type        = string
  default     = null
}

variable "baselines" {
  description = <<-EOT
    Map of patch baselines to create, keyed by an arbitrary baseline_key.
    Each value:
      operating_system : SSM patch OS (for example ALMA_LINUX, REDHAT_ENTERPRISE_LINUX).
      patch_group      : value written to the Patch Group tag and targeted by associations.
      sources          : list of yum repo sources, each:
        name         : repo id / section name.
        product      : exact SSM patch source product (for example AlmaLinux8.10).
        baseurl_path : path appended under var.mirror_url to form baseurl.
        gpgkey_file  : gpg key filename under /etc/pki/rpm-gpg/.
  EOT
  type = map(object({
    operating_system = string
    patch_group      = string
    sources = list(object({
      name         = string
      product      = string
      baseurl_path = string
      gpgkey_file  = string
    }))
  }))

  # Generic 2-OS sample mirroring the os_matrix contract (baseurl_path is always
  # <os_prefix>/<component>, gpg key filenames match os_matrix.gpg_keys). The
  # Terragrunt layer overrides this with config.hcl patch_baselines.
  default = {
    alma810 = {
      operating_system = "ALMA_LINUX"
      patch_group      = "alma810"
      sources = [
        {
          name         = "frozen-baseos"
          product      = "AlmaLinux8.10"
          baseurl_path = "alma810/baseos"
          gpgkey_file  = "RPM-GPG-KEY-OS"
        },
        {
          name         = "frozen-appstream"
          product      = "AlmaLinux8.10"
          baseurl_path = "alma810/appstream"
          gpgkey_file  = "RPM-GPG-KEY-OS"
        },
        {
          name         = "frozen-epel"
          product      = "AlmaLinux8.10"
          baseurl_path = "alma810/epel"
          gpgkey_file  = "RPM-GPG-KEY-EPEL"
        },
      ]
    }
  }
}

variable "tags" {
  description = "Additional tags applied to all resources."
  type        = map(string)
  default     = {}
}
