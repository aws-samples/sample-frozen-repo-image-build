#!/usr/bin/env bash
# Bootstrap the Terraform state backend for the two-account deployment. Idempotently creates:
#   1. Remote-state S3 bucket in the Distribution account (versioned, SSE-S3, public-access-blocked, TLS-only).
#   2. A DynamoDB lock table in EACH account: the S3 backend resolves the table name in the caller's account,
#      so the Workload identity needs a same-named table (safe; the accounts write disjoint state key spaces).
#   3. A bucket policy granting the Workload principal least-privilege access (rw Workload/*, ro frozen-store state).
# Names/ids come from environments/config.hcl; Workload principal from workload_deploy_principal_arn or deploy_role_name.
#
# Usage: scripts/bootstrap.sh <dist-profile> <work-profile>
set -euo pipefail

DIST_PROFILE="${1:?usage: bootstrap.sh <dist-profile> <work-profile>}"
WORK_PROFILE="${2:?usage: bootstrap.sh <dist-profile> <work-profile>}"

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIG="$REPO_ROOT/environments/config.hcl"
test -f "$CONFIG" || { echo "ERROR: $CONFIG not found." >&2; exit 1; }

# Read a top-level string value from config.hcl: key = "value"
cfg() {
  sed -n "s/^ *$1 *= *\"\([^\"]*\)\".*/\1/p" "$CONFIG" | head -1
}

STATE_BUCKET="$(cfg state_bucket)"
LOCK_TABLE="$(cfg state_lock_table)"
STATE_REGION="$(cfg state_region)"
DIST_ACCOUNT="$(cfg distribution_account_id)"
WORK_ACCOUNT="$(cfg workload_account_id)"
DEPLOY_ROLE="$(cfg deploy_role_name)"
WORK_PRINCIPAL="$(cfg workload_deploy_principal_arn)"

for v in STATE_BUCKET LOCK_TABLE STATE_REGION DIST_ACCOUNT WORK_ACCOUNT; do
  test -n "${!v}" || { echo "ERROR: $v not set in config.hcl." >&2; exit 1; }
done

# Resolve the Workload deploy principal for the cross-account state grant.
if [ -z "$WORK_PRINCIPAL" ]; then
  if [ -n "$DEPLOY_ROLE" ]; then
    WORK_PRINCIPAL="arn:aws:iam::${WORK_ACCOUNT}:role/${DEPLOY_ROLE}"
  else
    echo "ERROR: cannot resolve the Workload deploy principal." >&2
    echo "  Set workload_deploy_principal_arn in config.hcl (the IAM identity" >&2
    echo "  that runs 'make workload'), or set deploy_role_name." >&2
    exit 1
  fi
fi

echo "== bootstrap: state bucket $STATE_BUCKET ($STATE_REGION, Distribution $DIST_ACCOUNT) =="
if aws s3api head-bucket --bucket "$STATE_BUCKET" --profile "$DIST_PROFILE" 2>/dev/null; then
  echo "   bucket exists"
else
  if [ "$STATE_REGION" = "us-east-1" ]; then
    aws s3api create-bucket --bucket "$STATE_BUCKET" \
      --region "$STATE_REGION" --profile "$DIST_PROFILE" >/dev/null
  else
    aws s3api create-bucket --bucket "$STATE_BUCKET" \
      --region "$STATE_REGION" --profile "$DIST_PROFILE" \
      --create-bucket-configuration "LocationConstraint=$STATE_REGION" >/dev/null
  fi
  echo "   bucket created"
fi
aws s3api put-bucket-versioning --bucket "$STATE_BUCKET" --profile "$DIST_PROFILE" \
  --versioning-configuration Status=Enabled
aws s3api put-bucket-encryption --bucket "$STATE_BUCKET" --profile "$DIST_PROFILE" \
  --server-side-encryption-configuration '{"Rules":[{"ApplyServerSideEncryptionByDefault":{"SSEAlgorithm":"AES256"}}]}'
aws s3api put-public-access-block --bucket "$STATE_BUCKET" --profile "$DIST_PROFILE" \
  --public-access-block-configuration 'BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true'
echo "   versioning + encryption + public-access-block ensured"

echo "== bootstrap: lock table $LOCK_TABLE in each account ($STATE_REGION) =="
for profile in "$DIST_PROFILE" "$WORK_PROFILE"; do
  if aws dynamodb describe-table --table-name "$LOCK_TABLE" \
       --region "$STATE_REGION" --profile "$profile" >/dev/null 2>&1; then
    echo "   [$profile] table exists"
  else
    aws dynamodb create-table --table-name "$LOCK_TABLE" \
      --attribute-definitions AttributeName=LockID,AttributeType=S \
      --key-schema AttributeName=LockID,KeyType=HASH \
      --billing-mode PAY_PER_REQUEST \
      --region "$STATE_REGION" --profile "$profile" >/dev/null
    aws dynamodb wait table-exists --table-name "$LOCK_TABLE" \
      --region "$STATE_REGION" --profile "$profile"
    echo "   [$profile] table created"
  fi
done

if [ "$DIST_ACCOUNT" = "$WORK_ACCOUNT" ]; then
  echo "== bootstrap: single-account setup, no cross-account state policy needed =="
else
  echo "== bootstrap: cross-account state access for $WORK_PRINCIPAL =="
  policy=$(cat <<POLICY
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "DenyInsecureTransport",
      "Effect": "Deny",
      "Principal": "*",
      "Action": "s3:*",
      "Resource": [
        "arn:aws:s3:::${STATE_BUCKET}",
        "arn:aws:s3:::${STATE_BUCKET}/*"
      ],
      "Condition": {"Bool": {"aws:SecureTransport": "false"}}
    },
    {
      "Sid": "WorkloadDeployList",
      "Effect": "Allow",
      "Principal": {"AWS": "${WORK_PRINCIPAL}"},
      "Action": "s3:ListBucket",
      "Resource": "arn:aws:s3:::${STATE_BUCKET}",
      "Condition": {"StringLike": {"s3:prefix": ["Workload/*", "Distribution/us-west-2/frozen-store/*"]}}
    },
    {
      "Sid": "WorkloadDeployOwnState",
      "Effect": "Allow",
      "Principal": {"AWS": "${WORK_PRINCIPAL}"},
      "Action": ["s3:GetObject", "s3:PutObject", "s3:DeleteObject"],
      "Resource": "arn:aws:s3:::${STATE_BUCKET}/Workload/*"
    },
    {
      "Sid": "WorkloadDeployReadFrozenStoreOutputs",
      "Effect": "Allow",
      "Principal": {"AWS": "${WORK_PRINCIPAL}"},
      "Action": "s3:GetObject",
      "Resource": "arn:aws:s3:::${STATE_BUCKET}/Distribution/us-west-2/frozen-store/terraform.tfstate"
    }
  ]
}
POLICY
)
  aws s3api put-bucket-policy --bucket "$STATE_BUCKET" \
    --profile "$DIST_PROFILE" --policy "$policy"
  echo "   bucket policy applied (TLS-only + least-privilege Workload access)"
fi

echo "== bootstrap complete =="
echo "   NOTE: do NOT pre-create the ECR repos; the sync-engine and mirror"
echo "   modules create and manage them (pre-creating causes a"
echo "   RepositoryAlreadyExists failure at apply)."
