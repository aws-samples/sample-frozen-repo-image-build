# Shared config for the patch-manager component (DRY layer).
# Per-OS baselines come from config.hcl (local.cfg.patch_baselines) through the leaf.

terraform {
  source = "${get_repo_root()}/modules/patch-manager"
}

inputs = {
  scan_schedule    = "cron(0 22 ? * SAT *)"
  install_schedule = "cron(0 2 ? * SUN *)"
}
