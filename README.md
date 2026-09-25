# Frozen Package Repository for Air-Gapped EC2 Image Builds

A sanitized Terraform/Terragrunt reference for an **air-gapped OS package pipeline** on AWS. An operator-authorized initial baseline and later human-approved changes land in a version-pinned S3 "frozen" repository. EC2 Image Builder bakes AMIs from it, and a no-egress fleet resolves every `dnf` operation only to it.

> Sanitized reference, not production configuration: every account id, ARN, VPC/subnet id, domain, and email is a placeholder to replace via the Terragrunt input files.

## The three pillars

1. **Frozen package repository (Amazon S3):** a version-pinned, versioned snapshot containing an operator-authorized baseline plus later approved changes.
2. **EC2 Image Builder** bakes golden AMIs from that snapshot; the same frozen state reproduces the same AMI.
3. **No-egress fleet:** every DNF install, upgrade, and SSM patch resolves only to the frozen mirror. No public repository fallback, by design.

## Architecture

![Two-account architecture](docs/diagrams/frozen-repo-architecture.svg)

- **Distribution account** (connected, the only writer): frozen S3 bucket (`us-west-2`) + control plane (DynamoDB, KMS, SNS, three Lambdas, Fargate sync task, `us-east-1`). Only this account reaches the internet, only for upstream fetches. The Region split is illustrative; co-locate the control plane and store unless residency or DR requirements justify cross-Region operation.
- **Workload account** (air-gapped, read-only): HTTPS mirror, EC2 Image Builder, SSM Patch Manager, and the fleet. It reads the bucket cross-account but cannot write it.

> The two accounts need **no network connectivity**: every cross-account access is an S3/KMS API call authorized by IAM (bucket policy, key policy, `aws:ResourceAccount` / `kms:ViaService` conditions). No peering or Transit Gateway; the VPC CIDRs may even overlap.

## End-to-end workflow

![End-to-end workflow](docs/diagrams/frozen-repo-workflow.svg)

An explicitly authorized `full-sync` establishes the initial baseline. EventBridge then fires the **detector** on a customer-defined schedule (monthly by default); it diffs each upstream repo against `manifest.json`, writes `candidates.json`, and SNS-emails a KMS-protected review link. A **human approves** selected changes on the API Gateway review page. The **approver** performs a single-use DynamoDB transition and starts the **Fargate sync task**. The task fails closed if the approval artifact is unavailable, requires every approved package download to succeed, and accepts only RPMs with a valid trusted signature. On task stop, the **manifest updater** rebuilds `manifest.json`. In the Workload account the **mirror** serves the bucket over HTTPS; **Image Builder** bakes AMIs from it and **Patch Manager** patches the fleet from the same source.

## Repository layout

```
frozen-repo-aws/
├── modules/                  # 9 Terraform modules (AWS provider ~> 6.0)
│   ├── frozen-store/  control-plane-data/  sync-engine/
│   ├── detector-lambda/  approver-lambda/  manifest-updater/
│   └── mirror/  patch-manager/  image-builder/
├── lambdas/                  # detector/  approver/  manifest_updater/  (Python)
├── containers/               # sync/ (reposync + GPG verify + S3)  mirror/ (nginx + sigv4)
├── environments/             # Terragrunt layer
│   ├── config.hcl            # THE single "fill these in" file (all real values + os_matrix)
│   ├── root.hcl              # provider (assume-role), remote state, tags
│   ├── _env/                 # per-component module source + stable inputs (DRY)
│   ├── Distribution/{account.hcl, us-west-2/frozen-store, us-east-1/<5 units>}
│   └── Workload/{account.hcl, us-west-2/{mirror, patch-manager, image-builder}}
└── docs/diagrams/
```

The directory path is the configuration: each leaf includes `root.hcl` (provider + assume-role + remote state from `config.hcl`/`account.hcl`) and its `_env/<component>.hcl` (module source + stable inputs), so a leaf carries only what varies. Cross-unit wiring uses `dependency` blocks with `mock_outputs`.

## Prerequisites

Work through these in order. Steps 1-3 are your machine; 4-6 are account networking (missing pieces fail at RUNTIME, not at apply); 7 is optional.

1. **Two AWS accounts**: a connected Distribution account and an air-gapped Workload account.
2. **Tools on the deploy machine**: Terraform >= 1.5, Terragrunt, a container engine (Finch, the default, or Docker), and `python3` + `pip` (`make distribution` vendors Lambda pip dependencies via `make lambda-deps`; without it the functions fail at import time).
3. **AWS CLI with one named profile per account**; you pass them to every `make` target as `DIST_PROFILE` and `WORK_PROFILE`.
4. **Distribution account networking**:
   - Private subnets whose internet egress works **without public IPs** (NAT gateway or equivalent). VPC-attached Lambdas never get public IPs and the sync task runs with `assignPublicIp` disabled, so an internet gateway alone is not enough.
   - The security group in `distribution_security_group_id` allows **egress on 443** (AWS APIs + public package mirrors; mirror CDNs have no stable CIDR to scope to).
   - VPC DNS resolves **public names** (Amazon-provided resolver or a forwarding resolver).
5. **Workload account networking**:
   - VPC **interface endpoints** for `ssm`, `ssmmessages`, `ec2messages`, `logs`, `kms`, and `imagebuilder`, plus the S3 **gateway** endpoint. All six are required in a truly air-gapped VPC; `imagebuilder` is the easiest to miss.
   - The security groups in `workload_security_group_ids` (used by the Image Builder build instance) allow **egress on 443** to the VPC CIDR (the endpoints + the mirror ALB) and to the S3 managed prefix list (component downloads and log upload).
6. **Mirror hostname**: an ACM certificate (private CA or imported) and a private hosted zone for the internal mirror name. The build instance and the fleet verify the mirror's certificate with default TLS verification, so the CA must be trusted: preferably the parent AMI already trusts it (corporate root baked upstream); otherwise set `mirror_ca_cert_file` in `config.hcl` to the certificate's PEM and the bake installs the trust anchor before its first dnf call (also the path for a self-signed test certificate).
7. **Optional**: a `FrozenRepoDeploymentRole` in each account, assumable by your deploy identity. Leave `deploy_role_name` empty to use each profile's ambient credentials instead.

That is everything you pre-create. The Terraform state backend is created by `make bootstrap` (state bucket in the Distribution account, a lock table in EACH account, and a least-privilege cross-account bucket policy for the Workload deploy identity), and the ECR repositories are owned by the `sync-engine` and `mirror` units — do NOT pre-create them; images push after those units apply.

Missing networking shows up as one of these runtime failures:

| Symptom | Missing prerequisite |
|---|---|
| Every AWS call fails with `Could not connect to the endpoint URL` | Public DNS resolution (step 4), e.g. a DHCP options set pointing at an unreachable resolver |
| Pipeline fails at `LaunchBuildInstance` with `ssm:SendCommand InvalidInstanceId` | The SSM endpoint path or SG egress to it (step 5); the build instance never registered |
| Build fails at `ApplyBuildComponents` with `dial tcp ...: i/o timeout` | The `imagebuilder` interface endpoint (step 5); AWSTOE cannot call `GetComponent` |
| Bake fails at `ValidateFrozenRepo` with a TLS/certificate error | Mirror CA trust (step 6); set `mirror_ca_cert_file` or bake the CA into the parent |

## Configure

All real values live in **`environments/config.hcl`**: account ids, deploy role name, state bucket/table, VPC/subnet/SG ids, CIDRs, mirror hostname + ACM cert + zone, EBS KMS keys, approver email, and the `os_matrix`. The approver address gets an SNS subscription-confirmation email on first apply; review links are delivered only after it is confirmed once. When `deploy_role_name` is empty, also set `workload_deploy_principal_arn` (the identity that runs `make workload`) so bootstrap can grant it state access. `Distribution/account.hcl` and `Workload/account.hcl` carry only each account's id and name (must match `config.hcl`).

Onboarding an OS is one `os_matrix` block; the repo skeleton, detection, sync, patch baselines, and (when `build_ami = true`) an AMI pipeline all derive from it:

```hcl
os_matrix = {
  alma810 = {
    repos         = { baseos = "...", appstream = "...", epel = "..." }  # AlmaLinux vault + EPEL
    patch_os      = "ALMA_LINUX"
    patch_product = "AlmaLinux8.10"  # exact SSM product identifier
    gpg_keys      = { baseos = "RPM-GPG-KEY-OS", ... }
    build_ami     = true
    parent_image  = "ami-..."  # AlmaLinux 8.10 parent
    # Optional: curated list the bake installs FROM the frozen mirror (same file
    # validate_packages.sh checks after each sync), so AMI content is frozen-repo-sourced.
    baked_packages_file = "containers/sync/pkg-lists/custom_packages_alma810.txt"
  }
}
```

The active sample defaults to the AlmaLinux 8.10 lineage. AlmaLinux 7 does not exist, so this DNF-only reference does not include the former CentOS 7.9 example.

For genuine RHEL, replace or extend the matrix with a distinct `rhel810` entry, set `patch_os = "REDHAT_ENTERPRISE_LINUX"`, point `repos` at an entitled Red Hat content source, and provide Red Hat signing keys to both the sync image and Image Builder. The repository does not provision Red Hat subscription credentials. `parent_image`, `repos`, and `gpg_keys` must all use the same distribution lineage; do not mix AlmaLinux and Red Hat artifacts.

## Detailed setup

Follow this sequence for a new environment. Replace every angle-bracket value before running a command.

### 1. Verify tools and AWS identities

```bash
terraform version                 # 1.5 or later
terragrunt --version
aws --version
python3 --version
finch --version                   # or: docker --version

aws sts get-caller-identity --profile <distribution-profile>
aws sts get-caller-identity --profile <workload-profile>
```

Confirm that each identity targets the intended account and can assume `deploy_role_name` when that setting is non-empty. Do not continue if either account id differs from `environments/config.hcl`.

### 2. Complete the central configuration

Edit `environments/config.hcl` and verify all of the following:

- Distribution and Workload account ids and deployment-role settings.
- Globally unique Terraform-state and frozen-store bucket names.
- VPC, private-subnet, security-group, CIDR, Route 53 private-zone, ACM certificate, and mirror-hostname values.
- Per-Region EBS KMS keys and the Image Builder component KMS key.
- Approver email address, AlmaLinux parent AMI, upstream repositories, and signing-key filenames.
- `mirror_create_vpc_endpoints = false` when the Workload VPC already has the required endpoints. Existing endpoint security groups must allow HTTPS from the mirror and build workloads.
- All teardown controls remain protected during setup: `frozen_store_force_destroy = false`, both ECR `force_delete` values are `false`, and `mirror_enable_deletion_protection = true`.

Ensure `environments/Distribution/account.hcl` and `environments/Workload/account.hcl` contain the same account ids and names selected in the central configuration.

### 3. Validate locally

```bash
make check-config
make test
```

`make check-config` rejects every shipped account, network, AMI, repository, DNS, certificate, email, and bucket placeholder. `make test` runs the security regression tests and shell syntax checks.

### 4. Bootstrap remote state

```bash
make bootstrap \
  DIST_PROFILE=<distribution-profile> \
  WORK_PROFILE=<workload-profile>
```

This creates the versioned state bucket in the Distribution account, one DynamoDB lock table in each account, and the least-privilege state-bucket policy needed by the Workload deploy identity. The command is idempotent. Do not pre-create the application ECR repositories.

### 5. Review every Terraform plan

```bash
make plan \
  DIST_PROFILE=<distribution-profile> \
  WORK_PROFILE=<workload-profile>
```

Review resource counts, account ids, Regions, IAM principals, KMS keys, VPC/subnet selections, endpoint creation, bucket names, DNS records, and deletion-protection settings. Resolve every unexpected replacement or cross-account principal before applying.

### 6. Deploy infrastructure and images

```bash
make distribution DIST_PROFILE=<distribution-profile>
make workload WORK_PROFILE=<workload-profile>
make images \
  DIST_PROFILE=<distribution-profile> \
  WORK_PROFILE=<workload-profile> \
  CONTAINER=finch
```

Use `CONTAINER=docker` when Docker is the local engine. Infrastructure must be applied before image push because Terraform owns both ECR repositories.

### 7. Establish and verify the initial baseline

Review the configured upstream repositories and obtain operator authorization before running:

```bash
make full-sync \
  BASELINE_APPROVED=true \
  DIST_PROFILE=<distribution-profile>
```

The target starts a Fargate task, waits until it stops, and fails unless the `sync` container exits with code 0. It can run for hours and transfer substantial data through the Distribution NAT path. When it succeeds, invoke the detector once:

```bash
make seed DIST_PROFILE=<distribution-profile>
```

Confirm the SNS email subscription before expecting review emails. Complete all checks in **Post-setup verification** before using a generated AMI or enabling scheduled patch installation.

## Deploy (dependency order)

```bash
make plan DIST_PROFILE=... WORK_PROFILE=...   # review every unit's plan first (no changes)
make all BASELINE_APPROVED=true DIST_PROFILE=... WORK_PROFILE=...   # includes operator-authorized full-sync
```

Or step by step, in the same order:

```bash
make bootstrap DIST_PROFILE=... WORK_PROFILE=...   # state bucket, lock table per account, cross-account state policy
make distribution DIST_PROFILE=...                 # apply the Distribution account
make workload WORK_PROFILE=...                     # apply the Workload account
make images DIST_PROFILE=... WORK_PROFILE=...      # build + push the sync and mirror images (amd64)
make full-sync BASELINE_APPROVED=true DIST_PROFILE=... # operator-authorized initial baseline (hours)
make seed DIST_PROFILE=...                         # invoke the detector once to baseline the manifest
```

The order is load-bearing: the state backend must exist before any plan, Distribution before the Workload mirror can read its bucket, the accounts before the image pushes, and the explicitly authorized `full-sync` baseline before detector seeding. `run --all apply` auto-approves; run `make plan` first. Single unit: `make unit DIR=environments/<Account>/<region>/<component>`. Teardown: `make destroy-workload` then `make destroy-distribution`.

## Building the container images

`make images` builds with `--platform=linux/amd64`, logs in to ECR, and pushes. The platform flag matters on Apple Silicon: the task definitions run on Fargate's default `LINUX/X86_64`, and an arm64 image fails at task start. The ECR repos use immutable tags, so a wrong push must be deleted before the tag can be reused. Swap Finch for Docker with `make images CONTAINER=docker`. The mirror build uses `aws-sigv4-proxy` v1.12 or later and pins the reviewed v1.12 release commit immutably; keep that pin current through dependency-update reviews.

## Run the pipeline

- **Detect out of cycle:** invoke the detector Lambda; it emails a review link when upstream changed.
- **Approve:** open the link, select packages, submit. Approval starts the sync task automatically.
- **Bake an AMI:** start a pipeline execution when the package list, a component, or the parent image changes (the schedule is manual).

## Post-setup verification

1. **Applies clean:** `make plan` shows no unexpected diffs.
2. **Frozen store populated:** `aws s3 ls s3://<bucket>/alma810/baseos/repodata/ --profile <dist>` shows repo metadata, and `manifest.json` exists at the bucket root.
3. **Approval loop:** approve a package from the emailed link; the DynamoDB row flips to `approved` and a sync task runs.
4. **Mirror serves:** from a Workload host, `curl -I https://<mirror-host>/alma810/baseos/repodata/repomd.xml` returns 200.
5. **AMI bakes from the mirror only:** `aws imagebuilder start-image-pipeline-execution --image-pipeline-arn <arn> --region us-west-2 --profile <work>` succeeds.
6. **No-egress fleet:** on an instance from the baked AMI in a no-egress subnet, `dnf repolist` shows only the `frozen-<component>` repos (e.g. `frozen-baseos`, `frozen-appstream`, `frozen-epel`) and installs succeed with no internet route.
7. **Patch path:** the SSM `AWS-RunPatchBaseline` association patches from the same mirror.

A failure points at the responsible unit: (2) frozen-store/sync-engine, (3) approver/control-plane-data, (4) mirror, (5)/(6) image-builder, (7) patch-manager.

## Cleanup and teardown

Cleanup is destructive. Confirm the AWS identities, account ids, Regions, bucket names, and repository names before proceeding. Export any manifests, approval records, CloudTrail evidence, AMI ids, or logs that must be retained.

### 1. Stop consumers and identify retained artifacts

- Stop launching instances from generated AMIs and detach them from launch templates or Auto Scaling groups.
- Disable external automation that invokes the detector, approves requests, starts Image Builder pipelines, or runs Patch Manager associations.
- Record any Image Builder AMIs and EBS snapshots that must be retained. Terraform removes the pipeline configuration, but previously produced AMIs and snapshots may require separate lifecycle handling.
- Confirm that no sync task or image build is running.

### 2. Explicitly unlock protected resources

Change only these values in `environments/config.hcl`:

```hcl
frozen_store_force_destroy        = true
sync_ecr_force_delete             = true
mirror_ecr_force_delete           = true
mirror_enable_deletion_protection = false
```

These controls default to the protected values `false`, `false`, `false`, and `true`. Setting them as shown authorizes Terraform to empty the versioned frozen bucket, delete non-empty ECR repositories, and remove the protected ALB.

Apply the protection changes before destroy:

```bash
(
  cd environments/Workload/us-west-2/mirror
  AWS_PROFILE=<workload-profile> terragrunt plan
  AWS_PROFILE=<workload-profile> terragrunt apply
)
(
  cd environments/Distribution/us-east-1/sync-engine
  AWS_PROFILE=<distribution-profile> terragrunt plan
  AWS_PROFILE=<distribution-profile> terragrunt apply
)
(
  cd environments/Distribution/us-west-2/frozen-store
  AWS_PROFILE=<distribution-profile> terragrunt plan
  AWS_PROFILE=<distribution-profile> terragrunt apply
)
```

Review each plan. The intended changes are limited to ALB deletion protection, ECR `force_delete`, and S3 `force_destroy` behavior.

If teardown is postponed or cancelled after this apply, immediately restore the four protected values shown in **Detailed setup**, then plan and apply the same three units again. Do not leave deletion protection disabled or force-deletion controls armed in a running environment.

### 3. Destroy in reverse dependency order

```bash
make destroy-workload WORK_PROFILE=<workload-profile>
make destroy-distribution DIST_PROFILE=<distribution-profile>
```

Never reverse this order. The Workload mirror reads the Distribution frozen store and KMS key, so destroying Distribution first creates cross-account dependency and state-read failures.

If a destroy fails, correct the specific protection or dependency problem and rerun the same target. Do not remove resources from Terraform state merely to bypass a failed cloud deletion.

### 4. Verify application-resource removal

Check both accounts for resources intentionally or operationally left behind:

- Generated AMIs and their EBS snapshots.
- CloudWatch log groups retained outside Terraform.
- KMS keys in their scheduled-deletion windows.
- S3 buckets or ECR repositories whose deletion was denied by organization policy.
- Existing VPC endpoints that were not created by this stack.

Do not delete an AMI or snapshot still referenced by a launch template, Auto Scaling group, recovery plan, or audit record.

### 5. Optionally remove the bootstrap backend

`make destroy-*` intentionally does not delete the remote-state backend created by `make bootstrap`. Retain it when the environment may be recreated or when state history is required.

For complete removal, first confirm every Terragrunt state has been destroyed successfully. Then, using your organization-approved procedure for a **versioned S3 bucket**, delete all state-object versions and delete markers from `state_bucket`. After the bucket is empty:

1. Delete the state-bucket policy and bucket in the Distribution account.
2. Delete `state_lock_table` from the Distribution account.
3. Delete the same lock table from the Workload account.

The backend cleanup is deliberately not automated because deleting Terraform state before resource destruction can orphan infrastructure and remove the recovery path.

## Security notes

- The approver page sits behind an API Gateway HTTP API (Lambda resource policy names only that API; stage throttled and access-logged); authorization is the app-layer KMS-signed token. Add WAF or an SSO front for stricter postures.
- Split-access token KMS key: detector Encrypt-only, approver Decrypt-only, making the review link unforgeable.
- The frozen-store customer-managed key is retained for explicit cross-account key-policy control, not because public RPM bytes are confidential. Object-level audit requires CloudTrail S3 data events.
- Accepted security debt and production-hardening steps are documented in `SECURITY.md`.

## Compliance

The account, network, approval, and manifest controls can help produce evidence for change-management and patch-management requirements. Whether that evidence satisfies SOC 2, ISO 27001, FDA 21 CFR Part 11, or another framework depends on the deployment, audit scope, and assessor.
