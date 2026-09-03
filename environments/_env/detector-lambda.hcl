# Shared config for the detector-lambda component (DRY layer).
# OS upstream map comes from config.hcl (local.cfg.upstream_repos) through the leaf.

terraform {
  source = "${get_repo_root()}/modules/detector-lambda"
}

inputs = {
  function_name       = "frozenrepo-package-detector"
  token_expiry_hours  = 336
  schedule_expression = "cron(0 8 1 * ? *)"
  lambda_source_dir   = "${get_repo_root()}/lambdas/detector"
  s3_region           = "us-west-2"
}
