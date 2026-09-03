include "root" {
  path   = find_in_parent_folders("root.hcl")
  expose = true
}

include "env" {
  path   = "${get_repo_root()}/environments/_env/sync-engine.hcl"
  expose = true
}

dependency "frozen_store" {
  config_path = "../../us-west-2/frozen-store"
  mock_outputs = {
    bucket_name = "amzn-s3-demo-frozen-os-repos"
    bucket_arn  = "arn:aws:s3:::amzn-s3-demo-frozen-os-repos"
    kms_key_arn = "arn:aws:kms:us-west-2:111111111111:key/mock"
  }
  mock_outputs_allowed_terraform_commands = ["validate", "plan"]
}

dependency "control_plane" {
  config_path = "../control-plane-data"
  mock_outputs = {
    dynamodb_table_name  = "frozenrepo-package-update-requests"
    dynamodb_table_arn   = "arn:aws:dynamodb:us-east-1:111111111111:table/frozenrepo-package-update-requests"
    dynamodb_kms_key_arn = "arn:aws:kms:us-east-1:111111111111:key/mock-ddb"
  }
  mock_outputs_allowed_terraform_commands = ["validate", "plan"]
}

# Module source + upstream_repos_map + names come from _env/sync-engine.hcl.
inputs = {
  s3_bucket      = dependency.frozen_store.outputs.bucket_name
  s3_bucket_arn  = dependency.frozen_store.outputs.bucket_arn
  s3_kms_key_arn = dependency.frozen_store.outputs.kms_key_arn

  dynamodb_table       = dependency.control_plane.outputs.dynamodb_table_name
  dynamodb_table_arn   = dependency.control_plane.outputs.dynamodb_table_arn
  dynamodb_kms_key_arn = dependency.control_plane.outputs.dynamodb_kms_key_arn

  vpc_id     = include.root.locals.cfg.distribution_vpc_id
  subnet_ids = include.root.locals.cfg.distribution_subnet_ids

  # OS matrix (single source of truth in config.hcl).
  upstream_repos_map = include.root.locals.cfg.upstream_repos
}
