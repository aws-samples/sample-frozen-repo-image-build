# Shared config for the manifest-updater component (DRY layer).
terraform {
  source = "${get_repo_root()}/modules/manifest-updater"
}

inputs = {
  function_name     = "frozenrepo-manifest-updater"
  s3_region         = "us-west-2"
  lambda_source_dir = "${get_repo_root()}/lambdas/manifest_updater"
}
