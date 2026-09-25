# Shared config for the sync-engine component (DRY layer).
# OS upstream map comes from config.hcl (local.cfg.upstream_repos) through the leaf.

terraform {
  source = "${get_repo_root()}/modules/sync-engine"
}

inputs = {
  ecr_repo_name = "frozenrepo/frozen-repo-sync"
  task_family   = "frozenrepo-frozen-repo-sync"
  image_tag     = "v1.1.0"
  s3_region     = "us-west-2"
  additional_ecr_pull_repository_arns = [
    "arn:aws:ecr:us-east-1:593207742271:repository/aws-guardduty-agent-fargate",
  ]
}
