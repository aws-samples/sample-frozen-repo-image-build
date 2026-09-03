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
      operating_system : SSM patch OS (for example REDHAT_ENTERPRISE_LINUX, AMAZON_LINUX_2).
      patch_group      : value written to the Patch Group tag and targeted by associations.
      sources          : list of yum repo sources, each:
        name         : repo id / section name.
        product      : SSM patch source product (for example RedhatEnterpriseLinux8.10).
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
    rhel810 = {
      operating_system = "REDHAT_ENTERPRISE_LINUX"
      patch_group      = "rhel810"
      sources = [
        {
          name         = "frozen-baseos"
          product      = "RedhatEnterpriseLinux8.10"
          baseurl_path = "rhel810/baseos"
          gpgkey_file  = "RPM-GPG-KEY-OS"
        },
        {
          name         = "frozen-appstream"
          product      = "RedhatEnterpriseLinux8.10"
          baseurl_path = "rhel810/appstream"
          gpgkey_file  = "RPM-GPG-KEY-OS"
        },
        {
          name         = "frozen-epel"
          product      = "RedhatEnterpriseLinux8.10"
          baseurl_path = "rhel810/epel"
          gpgkey_file  = "RPM-GPG-KEY-EPEL"
        },
      ]
    }
    rhel79 = {
      operating_system = "REDHAT_ENTERPRISE_LINUX"
      patch_group      = "rhel79"
      sources = [
        {
          name         = "frozen-base"
          product      = "RedhatEnterpriseLinux7.9"
          baseurl_path = "rhel79/base"
          gpgkey_file  = "RPM-GPG-KEY-OS"
        },
        {
          name         = "frozen-updates"
          product      = "RedhatEnterpriseLinux7.9"
          baseurl_path = "rhel79/updates"
          gpgkey_file  = "RPM-GPG-KEY-OS"
        },
        {
          name         = "frozen-epel"
          product      = "RedhatEnterpriseLinux7.9"
          baseurl_path = "rhel79/epel"
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
