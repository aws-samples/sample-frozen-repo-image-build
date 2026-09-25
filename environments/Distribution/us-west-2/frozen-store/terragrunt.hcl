include "root" {
  path   = find_in_parent_folders("root.hcl")
  expose = true
}

include "env" {
  path   = "${get_repo_root()}/environments/_env/frozen-store.hcl"
  expose = true
}

# Only account-specific values live here; module source, repo_matrix, and other
# stable inputs come from _env/frozen-store.hcl.
inputs = {
  bucket_name   = include.root.locals.cfg.frozen_bucket_name
  force_destroy = include.root.locals.cfg.frozen_store_force_destroy

  # Workload account mirror task role (cross-account reader).
  mirror_task_role_arn = include.root.locals.cfg.mirror_task_role_arn

  # Distribution writers: sync task, the three Lambdas.
  writer_role_arns = include.root.locals.frozen_store_writer_role_arns

  # OS matrix (single source of truth in config.hcl).
  repo_matrix = include.root.locals.cfg.repo_matrix
}
