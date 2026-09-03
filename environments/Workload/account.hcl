# Workload account: air-gapped (no internet egress), read-only consumer of the
# frozen store. Runs the mirror, Patch Manager, and Image Builder.
# Account-specific only. All other settings are centralized in
# environments/config.hcl.
locals {
  aws_account_id = "222222222222" # Workload (air-gapped) account id
  account_name   = "frozenrepo-workload"
}
