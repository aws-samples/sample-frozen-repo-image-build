include "root" {
  path   = find_in_parent_folders("root.hcl")
  expose = true
}

include "env" {
  path   = "${get_repo_root()}/environments/_env/patch-manager.hcl"
  expose = true
}

dependency "mirror" {
  config_path = "../mirror"
  mock_outputs = {
    mirror_url = "https://frozen-repo.internal.example"
  }
  mock_outputs_allowed_terraform_commands = ["validate", "plan"]
}

# Scan/install schedules + module source come from _env/patch-manager.hcl.
# baselines are derived from the central os_matrix in config.hcl.
inputs = {
  mirror_url = dependency.mirror.outputs.mirror_url

  # OS matrix (single source of truth in config.hcl).
  baselines = include.root.locals.cfg.patch_baselines
}
