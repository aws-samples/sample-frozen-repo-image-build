# Root Terragrunt configuration (sanitized reference). Path IS the config: environments/<Account>/<Region>/<component>/.
# Each leaf reads the nearest account.hcl and config.hcl to assemble the provider, assume-role, remote state key, and tags; no client values live here (safe to publish).

locals {
  account_vars = read_terragrunt_config(find_in_parent_folders("account.hcl"))
  region_vars  = read_terragrunt_config(find_in_parent_folders("region.hcl"))
  config_vars  = read_terragrunt_config(find_in_parent_folders("config.hcl"))

  # Centralized user config (the single "fill these in" file).
  cfg = local.config_vars.locals

  aws_account_id     = local.account_vars.locals.aws_account_id
  aws_region         = local.region_vars.locals.aws_region
  account_name       = local.account_vars.locals.account_name
  deploy_role_name   = local.cfg.deploy_role_name
  name_prefix        = local.cfg.name_prefix
  state_bucket       = local.cfg.state_bucket
  state_lock_table   = local.cfg.state_lock_table
  state_region       = local.cfg.state_region

  # Derived role-ARN groupings the modules consume.
  control_plane_role_arns = [
    local.cfg.detector_role_arn,
    local.cfg.approver_role_arn,
    local.cfg.sync_task_role_arn,
  ]
  frozen_store_writer_role_arns = [
    local.cfg.sync_task_role_arn,
    local.cfg.detector_role_arn,
    local.cfg.approver_role_arn,
    local.cfg.manifest_updater_role_arn,
  ]
}

# Generate the AWS provider. assume_role hops into the target account via the per-account deploy role (CI/CD or local identity).
# When deploy_role_name is EMPTY the block is omitted and the caller's ambient credentials are used (e.g. an Isengard Admin session whose SCP denies sts:AssumeRole).
generate "provider" {
  path      = "provider.tf"
  if_exists = "overwrite_terragrunt"
  contents  = <<EOF
provider "aws" {
  region = "${local.aws_region}"
${local.deploy_role_name == "" ? "" : <<ROLE

  assume_role {
    role_arn     = "arn:aws:iam::${local.aws_account_id}:role/${local.deploy_role_name}"
    session_name = "frozenrepo-deploy"
  }
ROLE
}
  default_tags {
    tags = {
      Project   = "FrozenRepo"
      ManagedBy = "Terraform"
    }
  }
}
EOF
}

# Remote state in S3 with a DynamoDB lock table. The state key mirrors the folder
# tree, so state layout matches the deployment layout one-to-one.
remote_state {
  backend = "s3"
  generate = {
    path      = "backend.tf"
    if_exists = "overwrite_terragrunt"
  }
  config = {
    bucket                = local.state_bucket
    key                   = "${path_relative_to_include()}/terraform.tfstate"
    region                = local.state_region
    encrypt               = true
    dynamodb_table        = local.state_lock_table
    disable_bucket_update = true
  }
}

# Common inputs every unit receives.
inputs = {
  aws_account_id = local.aws_account_id
  aws_region     = local.aws_region
  name_prefix    = local.name_prefix
}
