# Distribution account: internet-connected, the only writer to the frozen store.
# Account-specific only. All other settings (deploy role, prefix, state, ARNs,
# networking, URLs) are centralized in environments/config.hcl.
locals {
  aws_account_id = "111111111111" # Distribution (connected) account id
  account_name   = "frozenrepo-distribution"
}
