# Shared config for the mirror component (DRY layer).
terraform {
  source = "${get_repo_root()}/modules/mirror"
}

inputs = {
  mirror_ecr_repo_name = "frozenrepo/frozen-repo-mirror"
  task_family          = "frozenrepo-frozen-repo-mirror"
  image_tag            = "v1.0.0"
  desired_count        = 3
}
