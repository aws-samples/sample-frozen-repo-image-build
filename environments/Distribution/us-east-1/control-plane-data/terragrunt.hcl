include "root" {
  path   = find_in_parent_folders("root.hcl")
  expose = true
}

include "env" {
  path   = "${get_repo_root()}/environments/_env/control-plane-data.hcl"
  expose = true
}

# Account-specific: role ARNs and approver email. Table/topic names + module
# source come from _env/control-plane-data.hcl.
inputs = {
  approval_email = include.root.locals.cfg.approval_email

  detector_role_arn = include.root.locals.cfg.detector_role_arn
  approver_role_arn = include.root.locals.cfg.approver_role_arn

  control_plane_role_arns = include.root.locals.control_plane_role_arns
}
