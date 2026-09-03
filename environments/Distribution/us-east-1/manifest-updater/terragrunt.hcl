include "root" {
  path   = find_in_parent_folders("root.hcl")
  expose = true
}

include "env" {
  path   = "${get_repo_root()}/environments/_env/manifest-updater.hcl"
  expose = true
}

dependency "frozen_store" {
  config_path = "../../us-west-2/frozen-store"
  mock_outputs = {
    bucket_name = "amzn-s3-demo-frozen-os-repos"
    kms_key_arn = "arn:aws:kms:us-west-2:111111111111:key/mock"
  }
  mock_outputs_allowed_terraform_commands = ["validate", "plan"]
}

dependency "sync_engine" {
  config_path = "../sync-engine"
  mock_outputs = {
    cluster_arn         = "arn:aws:ecs:us-east-1:111111111111:cluster/frozenrepo-sync-cluster"
    task_definition_arn = "arn:aws:ecs:us-east-1:111111111111:task-definition/frozenrepo-frozen-repo-sync"
  }
  mock_outputs_allowed_terraform_commands = ["validate", "plan"]
}

# Function name + s3_region + module source come from _env/manifest-updater.hcl.
inputs = {
  s3_bucket      = dependency.frozen_store.outputs.bucket_name
  s3_kms_key_arn = dependency.frozen_store.outputs.kms_key_arn

  sync_cluster_arn                = dependency.sync_engine.outputs.cluster_arn
  sync_task_definition_arn_prefix = dependency.sync_engine.outputs.task_definition_arn

  subnet_ids        = include.root.locals.cfg.distribution_subnet_ids
  security_group_id = include.root.locals.cfg.distribution_security_group_id

  # Scan matrix derived from the single os_matrix registry (same source as
  # frozen-store's skeleton), so manifest rebuilds cover exactly the store layout.
  repo_matrix = include.root.locals.cfg.repo_matrix
}
