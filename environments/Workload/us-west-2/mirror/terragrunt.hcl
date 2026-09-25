include "root" {
  path   = find_in_parent_folders("root.hcl")
  expose = true
}

include "env" {
  path   = "${get_repo_root()}/environments/_env/mirror.hcl"
  expose = true
}

# Cross-account read of the frozen store in the Distribution account.
dependency "frozen_store" {
  config_path = "../../../Distribution/us-west-2/frozen-store"
  mock_outputs = {
    bucket_name = "amzn-s3-demo-frozen-os-repos"
    bucket_arn  = "arn:aws:s3:::amzn-s3-demo-frozen-os-repos"
    kms_key_arn = "arn:aws:kms:us-west-2:111111111111:key/mock"
  }
  mock_outputs_allowed_terraform_commands = ["validate", "plan"]
}

# ECR/task names + image tag + desired_count + module source come from _env/mirror.hcl.
inputs = {
  frozen_bucket_arn         = dependency.frozen_store.outputs.bucket_arn
  frozen_bucket_kms_key_arn = dependency.frozen_store.outputs.kms_key_arn
  s3_bucket                 = dependency.frozen_store.outputs.bucket_name
  # Pin the cross-account S3 read to the Distribution account that owns the bucket.
  frozen_bucket_account_id = include.root.locals.cfg.distribution_account_id

  vpc_id        = include.root.locals.cfg.workload_vpc_id
  subnet_ids    = include.root.locals.cfg.workload_subnet_ids
  ingress_cidrs = include.root.locals.cfg.mirror_ingress_cidrs

  # Set mirror_create_vpc_endpoints = false in config.hcl when the workload
  # VPC already has the S3 gateway + KMS/ECR/Logs interface endpoints (only
  # one private-DNS interface endpoint per service per VPC is allowed).
  create_vpc_endpoints       = try(include.root.locals.cfg.mirror_create_vpc_endpoints, true)
  ecr_force_delete           = include.root.locals.cfg.mirror_ecr_force_delete
  enable_deletion_protection = include.root.locals.cfg.mirror_enable_deletion_protection

  acm_certificate_arn = include.root.locals.cfg.mirror_acm_cert_arn
  mirror_hostname     = include.root.locals.cfg.mirror_hostname
  private_zone_id     = include.root.locals.cfg.mirror_private_zone_id
  create_dns_record   = include.root.locals.cfg.mirror_create_dns_record
}
