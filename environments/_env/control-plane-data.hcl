# Shared config for the control-plane-data component (DRY layer).
terraform {
  source = "${get_repo_root()}/modules/control-plane-data"
}

inputs = {
  table_name = "frozenrepo-package-update-requests"
  topic_name = "frozenrepo-package-approval"
}
