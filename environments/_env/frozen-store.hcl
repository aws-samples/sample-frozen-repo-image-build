# Shared config for the frozen-store component (DRY layer).
# Leaf units add account-specific values (role ARNs, bucket name) plus repo_matrix from config.hcl (local.cfg.repo_matrix).

terraform {
  source = "${get_repo_root()}/modules/frozen-store"
}
