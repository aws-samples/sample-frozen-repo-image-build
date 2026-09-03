# EC2 Image Builder pipeline (bakes an AMI from the frozen mirror). Self-contained:
# build role/profile, two frozen-repo components, recipe, infra + distribution config, pipeline.

data "aws_caller_identity" "current" {}
data "aws_region" "current" {}
data "aws_partition" "current" {}

locals {
  # Accounts to share the built AMIs with, excluding the building account itself.
  external_share_account_ids = [
    for id in var.target_account_ids : id
    if id != data.aws_caller_identity.current.account_id
  ]

  common_tags = merge(
    {
      Module    = "image-builder"
      ManagedBy = "terraform"
    },
    var.tags,
  )

  # Per-image baked baseurl: <frozen_repo_url>/<os_prefix>
  frozen_baseurls = { for os, cfg in var.images : os => "${var.frozen_repo_url}/${os}" }

  # Per-OS repo file body, one section per component (repodata lives per component
  # in the frozen store: <os>/<component>/repodata/), matching the patch-manager
  # baselines so bake-time and patch-time resolve identically.
  frozen_repo_lines = {
    for os, cfg in var.images : os => flatten([
      for comp in sort(keys(cfg.repos)) : [
        "[frozen-${comp}]",
        "name=frozen ${comp}",
        "baseurl=${var.frozen_repo_url}/${os}/${comp}/",
        "enabled=1",
        "gpgcheck=1",
        "gpgkey=file:///etc/pki/rpm-gpg/${lookup(cfg.gpg_keys, comp, "RPM-GPG-KEY-OS")}",
        "",
      ]
    ])
  }

  # Per-OS distinct GPG key filenames the bake must install.
  image_gpg_keys = {
    for os, cfg in var.images : os => distinct(values(cfg.gpg_keys))
  }
}

#########################
# Build instance role / profile
#########################

data "aws_iam_policy_document" "assume" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "build" {
  name                 = "${var.name_prefix}-build-role"
  assume_role_policy   = data.aws_iam_policy_document.assume.json
  permissions_boundary = var.permissions_boundary_arn
  tags                 = local.common_tags
}

# SSM (Image Builder drives the instance over SSM).
resource "aws_iam_role_policy_attachment" "ssm" {
  role       = aws_iam_role.build.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

# Image Builder managed policy.
resource "aws_iam_role_policy_attachment" "imagebuilder" {
  role       = aws_iam_role.build.name
  policy_arn = "arn:aws:iam::aws:policy/EC2InstanceProfileForImageBuilder"
}

# Logs scoped to Image Builder's log-group namespace in this account/region. The build
# pulls packages over HTTPS from the mirror; S3 read granted only when frozen_bucket_arn is set.
data "aws_iam_policy_document" "build_inline" {
  dynamic "statement" {
    for_each = var.frozen_bucket_arn == null ? [] : [var.frozen_bucket_arn]
    content {
      sid    = "S3Read"
      effect = "Allow"
      actions = [
        "s3:GetObject",
        "s3:ListBucket",
      ]
      resources = [
        statement.value,
        "${statement.value}/*",
      ]
    }
  }

  statement {
    sid    = "ArtifactRead"
    effect = "Allow"
    actions = [
      "s3:GetObject",
      "s3:ListBucket",
    ]
    resources = [
      aws_s3_bucket.artifacts.arn,
      "${aws_s3_bucket.artifacts.arn}/*",
    ]
  }

  # Decrypt the SSE-KMS artifact objects (S3Download of the GPG keys), only via S3.
  statement {
    sid       = "ArtifactKmsDecrypt"
    effect    = "Allow"
    actions   = ["kms:Decrypt"]
    resources = [var.component_kms_key_arn]
    condition {
      test     = "StringEquals"
      variable = "kms:ViaService"
      values   = ["s3.${data.aws_region.current.region}.amazonaws.com"]
    }
  }

  statement {
    sid    = "Logs"
    effect = "Allow"
    actions = [
      "logs:CreateLogGroup",
      "logs:CreateLogStream",
      "logs:PutLogEvents",
    ]
    resources = [
      "arn:${data.aws_partition.current.partition}:logs:${data.aws_region.current.region}:${data.aws_caller_identity.current.account_id}:log-group:/aws/imagebuilder/*",
      "arn:${data.aws_partition.current.partition}:logs:${data.aws_region.current.region}:${data.aws_caller_identity.current.account_id}:log-group:/aws/imagebuilder/*:*",
    ]
  }
}

resource "aws_iam_role_policy" "build_inline" {
  name   = "${var.name_prefix}-build-inline"
  role   = aws_iam_role.build.id
  policy = data.aws_iam_policy_document.build_inline.json
}

resource "aws_iam_role_policy_attachment" "extra" {
  for_each   = toset(var.instance_profile_extra_policy_arns)
  role       = aws_iam_role.build.name
  policy_arn = each.value
}

resource "aws_iam_instance_profile" "build" {
  name = "${var.name_prefix}-build-profile"
  role = aws_iam_role.build.name
  tags = local.common_tags
}

#########################
# Components
#########################

locals {
  # Setup-component steps per OS. Conditional pieces: the mirror CA anchor is
  # installed FIRST (before any HTTPS fetch) when mirror_ca_cert_file is set;
  # the curated package list is installed from the frozen mirror AFTER the
  # mirror path has been validated, when baked_packages_file is set.
  setup_steps = {
    for os, cfg in var.images : os => concat(
      # jsondecode/jsonencode launders the conditional branches to a common type:
      # a bare  cond ? [] : [steps]  fails type-unification because the step
      # objects are heterogeneous (S3Download inputs is a list, ExecuteBash an
      # object). The content is yamlencode'd for AWSTOE, so types don't matter.
      jsondecode(var.mirror_ca_cert_file == "" ? "[]" : jsonencode([
        {
          name   = "DownloadMirrorCA"
          action = "S3Download"
          inputs = [
            {
              source      = "s3://${aws_s3_bucket.artifacts.id}/configs/mirror-ca.crt"
              destination = "/tmp/mirror-ca.crt"
            }
          ]
        },
        {
          name   = "InstallMirrorCA"
          action = "ExecuteBash"
          inputs = {
            commands = [
              "set -euo pipefail",
              "install -m 0644 /tmp/mirror-ca.crt /etc/pki/ca-trust/source/anchors/frozen-mirror.crt",
              "update-ca-trust extract",
              "rm -f /tmp/mirror-ca.crt",
            ]
          }
        },
      ])),
      [
        {
          # Real signing keys from the artifact bucket; gpgcheck=1 is useless
          # without them and dnf aborts on the first install.
          name   = "DownloadGpgKeys"
          action = "S3Download"
          inputs = [
            for k in local.image_gpg_keys[os] : {
              source      = "s3://${aws_s3_bucket.artifacts.id}/configs/${k}"
              destination = "/tmp/${k}"
            }
          ]
        },
        {
          name   = "InstallGpgKeys"
          action = "ExecuteBash"
          inputs = {
            commands = flatten([
              for k in local.image_gpg_keys[os] : [
                "install -m 0644 /tmp/${k} /etc/pki/rpm-gpg/${k}",
                "rpm --import /etc/pki/rpm-gpg/${k}",
                "rm -f /tmp/${k}",
              ]
            ])
          }
        },
        {
          name   = "BackupExistingRepos"
          action = "ExecuteBash"
          inputs = {
            commands = [
              "mkdir -p /etc/yum.repos.d.bak",
              "mv /etc/yum.repos.d/*.repo /etc/yum.repos.d.bak/ 2>/dev/null || true",
            ]
          }
        },
        {
          # One section per component: repodata lives at <os>/<component>/repodata/
          # in the frozen store, so a flat single-repo baseurl cannot serve dnf.
          # Then LOCK reposdir for the rest of the bake so no later component or
          # script can re-add an upstream repo.
          name   = "WriteFrozenReposAndLock"
          action = "ExecuteBash"
          inputs = {
            commands = concat(
              ["cat > /etc/yum.repos.d/frozen.repo <<'EOF'"],
              local.frozen_repo_lines[os],
              [
                "EOF",
                "mkdir -p /etc/yum.repos.d.frozen",
                "mv /etc/yum.repos.d/frozen.repo /etc/yum.repos.d.frozen/frozen.repo",
                "sed -i '/^reposdir=/d' /etc/dnf/dnf.conf",
                "echo 'reposdir=/etc/yum.repos.d.frozen' >> /etc/dnf/dnf.conf",
              ],
            )
          }
        },
        {
          # Force a repodata fetch THROUGH the mirror so the bake fails fast if
          # the frozen-repo path (ALB -> sigv4 -> cross-account S3) is broken,
          # instead of shipping an AMI that fails at first dnf use.
          # set -euo pipefail is load-bearing: AWSTOE runs these commands as one
          # script whose exit code is the LAST command's, so without it a failed
          # makecache is silently swallowed (observed live: TLS failure, step green).
          name   = "ValidateFrozenRepo"
          action = "ExecuteBash"
          inputs = {
            commands = [
              "set -euo pipefail",
              "dnf clean all",
              "dnf makecache",
              "dnf repolist --enabled",
              "echo 'Frozen mirror validated: repodata fetched through the mirror.'",
            ]
          }
        },
      ],
      jsondecode(cfg.baked_packages_file == "" ? "[]" : jsonencode([
        {
          name   = "DownloadPackageList"
          action = "S3Download"
          inputs = [
            {
              source      = "s3://${aws_s3_bucket.artifacts.id}/configs/${os}-packages.txt"
              destination = "/tmp/frozen-packages.txt"
            }
          ]
        },
        {
          # Install the curated list FROM the frozen mirror: the AMI content is
          # then frozen-repo-sourced and every bake moves real RPMs through it.
          name   = "InstallBakedPackages"
          action = "ExecuteBash"
          inputs = {
            commands = [
              "set -euo pipefail",
              "mapfile -t pkgs < <(sed -e 's/#.*//' -e 's/[[:space:]]*$//' /tmp/frozen-packages.txt | grep -v '^$' || true)",
              "echo \"Installing $${#pkgs[@]} curated packages from the frozen mirror\"",
              "if [ $${#pkgs[@]} -gt 0 ]; then dnf -y install \"$${pkgs[@]}\"; fi",
              "rm -f /tmp/frozen-packages.txt",
            ]
          }
        },
      ])),
    )
  }
}

resource "aws_imagebuilder_component" "frozen_repo_setup" {
  for_each = var.images

  name        = "${var.name_prefix}-${each.key}-frozen-repo-setup"
  platform    = "Linux"
  version     = "1.2.0"
  description = "Install GPG keys (and optional mirror CA), replace all yum repos with per-component frozen repos, lock reposdir, validate the mirror path, install the curated package list from the frozen mirror."
  kms_key_id  = var.component_kms_key_arn
  tags        = local.common_tags

  # Component versions are immutable: create the new version before destroying
  # the old so the recipe swap never dangles.
  lifecycle {
    create_before_destroy = true
  }

  data = yamlencode({
    name          = "frozen-repo-setup"
    description   = "Point the build to the frozen mirror only."
    schemaVersion = 1.0
    phases = [
      {
        name  = "build"
        steps = local.setup_steps[each.key]
      },
    ]
  })
}

resource "aws_imagebuilder_component" "frozen_repo_finalize" {
  for_each = var.images

  name        = "${var.name_prefix}-${each.key}-frozen-repo-finalize"
  platform    = "Linux"
  version     = "1.1.0"
  description = "Unlock reposdir, scrub any repo added during the build, leave the frozen repos as the AMI's only package source."
  kms_key_id  = var.component_kms_key_arn
  tags        = local.common_tags

  lifecycle {
    create_before_destroy = true
  }

  data = yamlencode({
    name          = "frozen-repo-finalize"
    description   = "Persist the frozen repo config into the image."
    schemaVersion = 1.0
    phases = [
      {
        name = "build"
        steps = [
          {
            # The bake-time reposdir lock comes off: at runtime the enforcement is
            # that /etc/yum.repos.d/ contains ONLY frozen.repo (every upstream repo
            # was deleted at setup and anything added mid-build is scrubbed here).
            name   = "UnlockReposdirAndScrub"
            action = "ExecuteBash"
            inputs = {
              commands = [
                "mv /etc/yum.repos.d.frozen/frozen.repo /etc/yum.repos.d/frozen.repo",
                "rm -rf /etc/yum.repos.d.frozen",
                "sed -i '/^reposdir=/d' /etc/dnf/dnf.conf",
                "find /etc/yum.repos.d/ -name '*.repo' ! -name 'frozen.repo' -delete",
                "rm -rf /etc/yum.repos.d.bak",
                "dnf clean all",
                "rm -rf /var/cache/dnf/*",
                "echo '=== final repo state ==='",
                "ls -l /etc/yum.repos.d/",
                "cat /etc/yum.repos.d/frozen.repo",
              ]
            }
          },
          {
            name   = "DropActiveMarker"
            action = "ExecuteBash"
            inputs = {
              commands = [
                "echo \"frozen-repo active: ${local.frozen_baseurls[each.key]}\" > /etc/frozen-repo-active",
                "chmod 0644 /etc/frozen-repo-active",
              ]
            }
          },
        ]
      },
    ]
  })
}

#########################
# Recipe
#########################

# Resolve each parent AMI so the block-device mapping targets its REAL root device:
# a wrong device name falls back to EBS encryption-by-default, and AMIs on the AWS-managed key cannot be shared at distribution.
data "aws_ami" "parent" {
  for_each = var.images

  filter {
    name   = "image-id"
    values = [each.value.parent_image]
  }
}

resource "aws_imagebuilder_image_recipe" "this" {
  for_each = var.images

  name = "${var.name_prefix}-${each.key}-recipe"
  # Recipes are IMMUTABLE: create_before_destroy repoints the pipeline to a new
  # recipe before deleting the old, so bump recipe_version whenever contents change.
  version = var.recipe_version

  lifecycle {
    create_before_destroy = true
  }

  parent_image = each.value.parent_image
  tags         = local.common_tags

  component {
    component_arn = aws_imagebuilder_component.frozen_repo_setup[each.key].arn
  }

  component {
    component_arn = aws_imagebuilder_component.frozen_repo_finalize[each.key].arn
  }

  dynamic "component" {
    for_each = var.extra_component_arns
    content {
      component_arn = component.value
    }
  }

  block_device_mapping {
    device_name = data.aws_ami.parent[each.key].root_device_name
    ebs {
      volume_size           = var.root_volume_size_gb
      volume_type           = "gp3"
      delete_on_termination = true
      encrypted             = true
      kms_key_id            = var.ebs_kms_key_arn
    }
  }
}

#########################
# Infrastructure configuration
#########################

resource "aws_imagebuilder_infrastructure_configuration" "this" {
  name                          = "${var.name_prefix}-infra"
  instance_profile_name         = aws_iam_instance_profile.build.name
  instance_types                = var.build_instance_types
  subnet_id                     = var.subnet_id
  security_group_ids            = var.security_group_ids
  terminate_instance_on_failure = true
  tags                          = local.common_tags
}

#########################
# Distribution configuration
#########################

resource "aws_imagebuilder_distribution_configuration" "this" {
  name = "${var.name_prefix}-dist"
  tags = local.common_tags

  dynamic "distribution" {
    for_each = var.distribution_regions
    content {
      region = distribution.value

      ami_distribution_configuration {
        name       = "${var.name_prefix}-{{ imagebuilder:buildDate }}"
        kms_key_id = lookup(var.region_kms_key_arns, distribution.value, null)

        # Share only to OTHER accounts: a same-account entry is a no-op at best and
        # at worst makes EC2 reject snapshots it considers unshareable.
        dynamic "launch_permission" {
          for_each = length(local.external_share_account_ids) > 0 ? [1] : []
          content {
            user_ids = local.external_share_account_ids
          }
        }
      }
    }
  }
}

#########################
# Pipeline (Manual schedule)
#########################

resource "aws_imagebuilder_image_pipeline" "this" {
  for_each = var.images

  name                             = "${var.name_prefix}-${each.key}-pipeline"
  image_recipe_arn                 = aws_imagebuilder_image_recipe.this[each.key].arn
  infrastructure_configuration_arn = aws_imagebuilder_infrastructure_configuration.this.arn
  distribution_configuration_arn   = aws_imagebuilder_distribution_configuration.this.arn
  status                           = "ENABLED"
  tags                             = local.common_tags

  # Manual: no schedule block means the pipeline runs only on demand.
}
