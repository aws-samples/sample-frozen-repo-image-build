include "root" {
  path   = find_in_parent_folders("root.hcl")
  expose = true
}

include "env" {
  path   = "${get_repo_root()}/environments/_env/detector-lambda.hcl"
  expose = true
}

dependency "approver" {
  config_path = "../approver-lambda"
  mock_outputs = {
    function_url = "https://mockapiid.execute-api.us-east-1.amazonaws.com"
  }
  mock_outputs_allowed_terraform_commands = ["validate", "plan"]
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

dependency "frozen_store" {
  config_path = "../../us-west-2/frozen-store"
  mock_outputs = {
    bucket_name = "amzn-s3-demo-frozen-os-repos"
    bucket_arn  = "arn:aws:s3:::amzn-s3-demo-frozen-os-repos"
    kms_key_arn = "arn:aws:kms:us-west-2:111111111111:key/mock"
  }
  mock_outputs_allowed_terraform_commands = ["validate", "plan"]
}

# Function name, schedule, token expiry, upstream_repos, and module source
# come from _env/detector-lambda.hcl.
inputs = {
  dynamodb_table_name  = dependency.control_plane.outputs.dynamodb_table_name
  dynamodb_table_arn   = dependency.control_plane.outputs.dynamodb_table_arn
  dynamodb_kms_key_arn = dependency.control_plane.outputs.dynamodb_kms_key_arn
  token_kms_key_arn    = dependency.control_plane.outputs.token_signing_key_arn
  sns_topic_arn        = dependency.control_plane.outputs.sns_topic_arn
  sns_kms_key_arn      = dependency.control_plane.outputs.sns_kms_key_arn

  s3_bucket      = dependency.frozen_store.outputs.bucket_name
  s3_bucket_arn  = dependency.frozen_store.outputs.bucket_arn
  s3_kms_key_arn = dependency.frozen_store.outputs.kms_key_arn

  apply_lambda_url = dependency.approver.outputs.function_url

  subnet_ids        = include.root.locals.cfg.distribution_subnet_ids
  security_group_id = include.root.locals.cfg.distribution_security_group_id

  # OS matrix (single source of truth in config.hcl).
  upstream_repos = include.root.locals.cfg.upstream_repos
}
