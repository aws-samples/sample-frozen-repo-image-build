# =============================================================================
# CENTRALIZED CONFIGURATION, the single "fill these in" file.
# =============================================================================
# This is the ONLY file you edit to point the stack at your own environment.
# Every leaf reads these values through the root include (local.cfg.*), so no
# account id, ARN, VPC id, hostname, or URL is hardcoded in a component.
#
# The values below are sanitized placeholders. Replace each one, then deploy.
# (The `arn:...:key/mock` values inside `dependency` blocks in the leaves are
# NOT config: they are plan-time mocks replaced by real outputs at apply time.
# Leave those alone.)
# =============================================================================

locals {
  # ---- Accounts --------------------------------------------------------------
  # These must match the aws_account_id in each account.hcl (account.hcl selects
  # which account a leaf targets; these let any leaf reference the OTHER account
  # for cross-account ARNs).
  distribution_account_id = "111111111111" # connected (writer) account
  workload_account_id     = "222222222222" # air-gapped (reader) account

  # Deployment role, same name in every target account; assumed by your CI/CD
  # (or a local identity) to deploy into each account.
  deploy_role_name = "FrozenRepoDeploymentRole"
  # Only needed when deploy_role_name is empty (ambient credentials): the IAM
  # identity that runs `make workload`, so `make bootstrap` can grant it
  # cross-account access to the state bucket. Ignored when deploy_role_name is set.
  workload_deploy_principal_arn = ""

  # Naming + remote state (state bucket lives in the Distribution account).
  name_prefix      = "frozenrepo"
  state_bucket     = "frozenrepo-terraform-state-111111111111"
  state_lock_table = "frozenrepo-terraform-locks"
  state_region     = "us-east-1"

  # ---- Names (derived; usually no need to change) ----------------------------
  frozen_bucket_name = "amzn-s3-demo-frozen-os-repos"

  # ---- IAM role ARNs the modules reference -----------------------------------
  # Distribution-side workload roles (sync task + the three Lambdas).
  detector_role_arn         = "arn:aws:iam::${local.distribution_account_id}:role/${local.name_prefix}-package-detector-role"
  approver_role_arn         = "arn:aws:iam::${local.distribution_account_id}:role/${local.name_prefix}-package-approver-role"
  sync_task_role_arn        = "arn:aws:iam::${local.distribution_account_id}:role/${local.name_prefix}-frozen-repo-sync-task-role"
  manifest_updater_role_arn = "arn:aws:iam::${local.distribution_account_id}:role/${local.name_prefix}-manifest-updater-role"
  # Workload-side mirror task role (cross-account reader of the frozen store).
  mirror_task_role_arn = "arn:aws:iam::${local.workload_account_id}:role/${local.name_prefix}-frozen-repo-mirror-task-role"

  # ---- Notification ----------------------------------------------------------
  approval_email = "package-approvers@example.com"

  # ---- Distribution networking (sync task + manifest updater in us-east-1) ----
  distribution_vpc_id            = "vpc-1111111111111111a"
  distribution_subnet_ids        = ["subnet-1111111111111111a", "subnet-1111111111111111b"]
  distribution_security_group_id = "sg-1111111111111111a"

  # ---- Workload networking (mirror + image builder in us-west-2) --------------
  workload_vpc_id             = "vpc-22222222222222222"
  workload_subnet_ids         = ["subnet-2222222222222222a", "subnet-2222222222222222b"]
  workload_security_group_ids = ["sg-2222222222222222a"]
  mirror_ingress_cidrs        = ["10.0.0.0/8"]

  # ---- Mirror endpoint (internal HTTPS) --------------------------------------
  mirror_hostname     = "frozen-repo.internal.example"
  mirror_acm_cert_arn = "arn:aws:acm:us-west-2:${local.workload_account_id}:certificate/mock-cert"

  # Optional TLS failsafe: absolute path to a PEM cert/CA chain the BAKE must
  # trust to reach the mirror over HTTPS. Leave "" when the parent AMI already
  # trusts the mirror certificate's CA (production posture: private CA root
  # baked upstream). Set it for a self-signed or not-yet-trusted certificate:
  # the bake installs the anchor before any dnf call and it is baked into the
  # AMI, so runtime dnf and SSM patching verify TLS too.
  mirror_ca_cert_file = ""
  mirror_private_zone_id     = "Z0000000000000000MOCK"
  mirror_create_dns_record   = true
  # Set false when this VPC already has the S3 gateway and KMS/ECR/Logs
  # interface endpoints; private-DNS interface endpoints are unique per VPC.
  mirror_create_vpc_endpoints = true

  # ---- Teardown safety ------------------------------------------------------
  # Keep these protections enabled during normal operation. The cleanup section
  # in README.md explains the explicit apply-before-destroy sequence.
  frozen_store_force_destroy          = false
  sync_ecr_force_delete               = false
  mirror_ecr_force_delete             = false
  mirror_enable_deletion_protection   = true

  # ---- Image Builder (account/network wiring; per-OS build settings live in os_matrix) ----
  image_target_account_ids = [local.workload_account_id]
  # Per-region EBS KMS keys for AMI encryption/distribution.
  image_region_kms_key_arns = {
    "us-west-2" = "arn:aws:kms:us-west-2:${local.workload_account_id}:key/mock-ebs-west"
    "us-east-1" = "arn:aws:kms:us-east-1:${local.workload_account_id}:key/mock-ebs-east"
  }
  # Customer-managed KMS key that encrypts Image Builder component data (build region).
  image_component_kms_key_arn = "arn:aws:kms:us-west-2:${local.workload_account_id}:key/mock-imagebuilder-component"
  image_distribution_regions  = ["us-west-2", "us-east-1"]

  # =============================================================================
  # THE OS REGISTRY, the single source of truth for every frozen OS.
  # =============================================================================
  # Add ONE block here to onboard a new OS end to end. Every component derives
  # from this map: the S3 repo skeleton (frozen-store), detection + sync
  # (detector/sync-engine), SSM patch baselines (patch-manager), and the AMI
  # pipeline (image-builder, only for entries with build_ami = true).
  #
  # Per OS:
  #   repos       : component name -> upstream URL (fetched in the Distribution
  #                 account). The component NAMES also define the S3 prefixes and
  #                 the frozen mirror paths (<os>/<component>).
  #   patch_os    : SSM operating_system (e.g. ALMA_LINUX or REDHAT_ENTERPRISE_LINUX).
  #   patch_product : exact SSM patch source product string for this OS.
  #   gpg_keys    : component name -> gpg key filename under /etc/pki/rpm-gpg/.
  #   build_ami   : whether image-builder bakes a golden AMI for this OS.
  #   parent_image: parent AMI id for the recipe (required when build_ami = true).
  # =============================================================================
  os_matrix = {
    alma810 = {
      repos = {
        baseos    = "https://repo.example.com/almalinux/8.10/BaseOS/x86_64/os/"
        appstream = "https://repo.example.com/almalinux/8.10/AppStream/x86_64/os/"
        epel      = "https://epel.example.com/8/Everything/x86_64/"
      }
      patch_os      = "ALMA_LINUX"
      # Verified with `aws ssm describe-patch-properties --operating-system
      # ALMA_LINUX --property PRODUCT`; use the exact SSM product identifier.
      patch_product = "AlmaLinux8.10"
      gpg_keys = {
        baseos    = "RPM-GPG-KEY-OS"
        appstream = "RPM-GPG-KEY-OS"
        epel      = "RPM-GPG-KEY-EPEL"
      }
      build_ami    = true
      # Same file validate_packages.sh checks after every sync: one source of truth.
      baked_packages_file = "containers/sync/pkg-lists/custom_packages_alma810.txt"
      parent_image = "ami-00000000000000000"
    }

    # Genuine RHEL subscription template (disabled). To use it, uncomment the
    # block, provide a Red Hat parent AMI, expose entitled Red Hat repositories
    # to the Distribution account, and add the Red Hat signing key to both the
    # sync image and modules/image-builder/files. Never reuse AlmaLinux keys.
    # rhel810 = {
    #   repos = {
    #     baseos    = "https://rhel-content.example.com/8.10/BaseOS/x86_64/os/"
    #     appstream = "https://rhel-content.example.com/8.10/AppStream/x86_64/os/"
    #   }
    #   patch_os      = "REDHAT_ENTERPRISE_LINUX"
    #   patch_product = "RedhatEnterpriseLinux8.10"
    #   gpg_keys = {
    #     baseos    = "RPM-GPG-KEY-redhat-release"
    #     appstream = "RPM-GPG-KEY-redhat-release"
    #   }
    #   build_ami           = true
    #   baked_packages_file = "containers/sync/pkg-lists/custom_packages_rhel810.txt"
    #   parent_image        = "ami-00000000000000000"
    # }
  }

  # ---- Derived views of os_matrix (components consume these; do not hand-edit) ----
  # frozen-store repo_matrix: os -> [component names]
  repo_matrix = { for os, v in local.os_matrix : os => keys(v.repos) }

  # detector / sync upstream map: os -> { component -> url }
  upstream_repos = { for os, v in local.os_matrix : os => v.repos }

  # patch-manager baselines: os -> baseline object (sources derived from repos + gpg_keys)
  patch_baselines = {
    for os, v in local.os_matrix : os => {
      operating_system = v.patch_os
      patch_group      = "${local.name_prefix}-frozen-${os}"
      sources = [
        for comp, url in v.repos : {
          name         = "frozen-${comp}"
          product      = v.patch_product
          baseurl_path = "${os}/${comp}"
          gpgkey_file  = lookup(v.gpg_keys, comp, "RPM-GPG-KEY-OS")
        }
      ]
    }
  }

  # image-builder images: only OS entries that need an AMI (keyed by os_prefix)
  image_builds = {
    for os, v in local.os_matrix : os => {
      parent_image = v.parent_image
      repos        = v.repos
      gpg_keys     = v.gpg_keys
      # Repo-relative path to the curated package list the bake installs from
      # the frozen mirror (same file validate_packages.sh checks after sync).
      # Empty skips the bake-time install.
      baked_packages_file = lookup(v, "baked_packages_file", "")
    } if v.build_ami
  }
}
