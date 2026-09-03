# Shared config for the image-builder component (DRY layer).
# Per-OS build set (parent images) comes from config.hcl (local.cfg.image_builds); one pipeline per OS, build_ami = true.

terraform {
  source = "${get_repo_root()}/modules/image-builder"
}

inputs = {
  name_prefix          = "frozenrepo"
  root_volume_size_gb  = 50
  build_instance_types = ["m6i.large"]
}
