include "root" {
  path   = find_in_parent_folders("root.hcl")
  expose = true
}

include "env" {
  path   = "${get_repo_root()}/environments/_env/image-builder.hcl"
  expose = true
}

dependency "mirror" {
  config_path = "../mirror"
  mock_outputs = {
    mirror_url = "https://frozen-repo.internal.example"
  }
  mock_outputs_allowed_terraform_commands = ["validate", "plan"]
}

# image name prefix, recipe settings, instance types, and module source come
# from _env/image-builder.hcl. The per-OS build set is derived from os_matrix.
inputs = {
  mirror_url      = dependency.mirror.outputs.mirror_url
  frozen_repo_url = dependency.mirror.outputs.mirror_url

  # OS matrix (single source of truth in config.hcl): one pipeline per OS with build_ami = true.
  # baked_packages_file is repo-relative in config.hcl; resolve it here so the module
  # reads the real file under Terragrunt's cache (same pattern as lambda_source_dir).
  images = {
    for os, v in include.root.locals.cfg.image_builds : os => merge(v, {
      baked_packages_file = v.baked_packages_file == "" ? "" : "${get_repo_root()}/${v.baked_packages_file}"
    })
  }

  # Optional TLS trust anchor for the mirror (absolute path or "" in config.hcl).
  mirror_ca_cert_file = include.root.locals.cfg.mirror_ca_cert_file

  subnet_id          = element(include.root.locals.cfg.workload_subnet_ids, 0)
  security_group_ids = include.root.locals.cfg.workload_security_group_ids

  distribution_regions  = include.root.locals.cfg.image_distribution_regions
  region_kms_key_arns   = include.root.locals.cfg.image_region_kms_key_arns
  component_kms_key_arn = include.root.locals.cfg.image_component_kms_key_arn
  target_account_ids    = include.root.locals.cfg.image_target_account_ids

  # CMK for the recipe's build-volume EBS encryption: the build region's key.
  # Without this the recipe silently falls back to the AWS-managed aws/ebs key.
  ebs_kms_key_arn = lookup(include.root.locals.cfg.image_region_kms_key_arns, "us-west-2", null)
}
