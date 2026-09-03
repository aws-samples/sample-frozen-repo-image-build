# Shared config for the approver-lambda component (DRY layer).
terraform {
  source = "${get_repo_root()}/modules/approver-lambda"
}

inputs = {
  function_name     = "frozenrepo-package-approver"
  lambda_source_dir = "${get_repo_root()}/lambdas/approver"
}
