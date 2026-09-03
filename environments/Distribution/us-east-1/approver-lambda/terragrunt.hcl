include "root" {
  path   = find_in_parent_folders("root.hcl")
  expose = true
}

include "env" {
  path   = "${get_repo_root()}/environments/_env/approver-lambda.hcl"
  expose = true
}

dependency "control_plane" {
  config_path = "../control-plane-data"
  mock_outputs = {
    dynamodb_table_name   = "frozenrepo-package-update-requests"
    dynamodb_table_arn    = "arn:aws:dynamodb:us-east-1:111111111111:table/frozenrepo-package-update-requests"
    dynamodb_kms_key_arn  = "arn:aws:kms:us-east-1:111111111111:key/mock-ddb"
    token_signing_key_arn = "arn:aws:kms:us-east-1:111111111111:key/mock-token"
    sns_topic_arn         = "arn:aws:sns:us-east-1:111111111111:frozenrepo-package-approval"
    sns_kms_key_arn       = "arn:aws:kms:us-east-1:111111111111:key/mock-sns"
  }
  mock_outputs_allowed_terraform_commands = ["validate", "plan"]
}

dependency "sync_engine" {
  config_path = "../sync-engine"
  mock_outputs = {
    cluster_name        = "frozenrepo-sync-cluster"
    cluster_arn         = "arn:aws:ecs:us-east-1:111111111111:cluster/frozenrepo-sync-cluster"
    task_family         = "frozenrepo-frozen-repo-sync"
    task_definition_arn = "arn:aws:ecs:us-east-1:111111111111:task-definition/frozenrepo-frozen-repo-sync"
    task_role_arn       = "arn:aws:iam::111111111111:role/frozenrepo-sync-task-role"
    task_exec_role_arn  = "arn:aws:iam::111111111111:role/frozenrepo-sync-exec-role"
    security_group_id   = "sg-1111111111111111a"
  }
  mock_outputs_allowed_terraform_commands = ["validate", "plan"]
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

# Function name + module source come from _env/approver-lambda.hcl.
inputs = {
  dynamodb_table_name  = dependency.control_plane.outputs.dynamodb_table_name
  dynamodb_table_arn   = dependency.control_plane.outputs.dynamodb_table_arn
  dynamodb_kms_key_arn = dependency.control_plane.outputs.dynamodb_kms_key_arn
  token_kms_key_arn    = dependency.control_plane.outputs.token_signing_key_arn
  sns_topic_arn        = dependency.control_plane.outputs.sns_topic_arn
  sns_kms_key_arn      = dependency.control_plane.outputs.sns_kms_key_arn

  # Encrypt the Lambda environment variables at rest with a customer-managed key
  # (reuse the token key: same account/region, already trusted by this function).
  env_kms_key_arn = dependency.control_plane.outputs.token_signing_key_arn

  s3_bucket      = dependency.frozen_store.outputs.bucket_name
  s3_bucket_arn  = dependency.frozen_store.outputs.bucket_arn
  s3_kms_key_arn = dependency.frozen_store.outputs.kms_key_arn

  ecs_cluster              = dependency.sync_engine.outputs.cluster_name
  ecs_cluster_arn          = dependency.sync_engine.outputs.cluster_arn
  ecs_task_family          = dependency.sync_engine.outputs.task_family
  sync_task_definition_arn = dependency.sync_engine.outputs.task_definition_arn
  sync_task_role_arn       = dependency.sync_engine.outputs.task_role_arn
  sync_exec_role_arn       = dependency.sync_engine.outputs.task_exec_role_arn
  ecs_subnet_ids           = include.root.locals.cfg.distribution_subnet_ids
  ecs_security_group       = dependency.sync_engine.outputs.security_group_id

  subnet_ids        = include.root.locals.cfg.distribution_subnet_ids
  security_group_id = include.root.locals.cfg.distribution_security_group_id
}
