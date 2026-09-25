#!/bin/bash
set -euo pipefail

# Frozen repo sync task: FULL_SYNC=true mirrors the whole upstream set; REQUEST_ID=<id> syncs only that request's approved packages.
# Upstream URLs come from UPSTREAM_REPOS_MAP (os_matrix-derived); keep in lockstep with the detector's UPSTREAM_REPOS map.

echo "=== Frozen Repo Sync Task ==="
echo "Timestamp: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
echo "Mode: ${FULL_SYNC:+FULL SYNC}${REQUEST_ID:+INCREMENTAL (request: $REQUEST_ID)}"
echo "S3 Bucket: ${S3_BUCKET} (${S3_REGION})"

acquire_lock() {
  # Sentinel captures stdout only: the python prints acquired/blocked/error:<msg>.
  local lock_result
  lock_result=$(python3 -c "
import boto3, os
from datetime import datetime, timedelta, timezone

ddb = boto3.client('dynamodb', region_name=os.environ['DYNAMODB_REGION'])
try:
    ddb.put_item(
        TableName=os.environ['DYNAMODB_TABLE'],
        Item={
            'request_id': {'S': 'SYNC_LOCK'},
            'status': {'S': 'locked'},
            'locked_at': {'S': datetime.now(timezone.utc).isoformat()},
            'expires_at': {'N': str(int((datetime.now(timezone.utc) + timedelta(hours=6)).timestamp()))},
        },
        ConditionExpression='attribute_not_exists(request_id) OR #s <> :locked',
        ExpressionAttributeNames={'#s': 'status'},
        ExpressionAttributeValues={':locked': {'S': 'locked'}},
    )
    print('acquired')
except ddb.exceptions.ConditionalCheckFailedException:
    print('blocked')
except Exception as e:
    print(f'error:{e}')
")

  if [[ "$lock_result" == "acquired" ]]; then
    return 0
  elif [[ "$lock_result" == "blocked" ]]; then
    echo "ERROR: Another sync task is already running. Exiting."
    exit 1
  else
    # Fail CLOSED on any DynamoDB error: a second concurrent sync could race the
    # --delete staging->prod promotion and corrupt the repo.
    echo "ERROR: Could not acquire sync lock (DynamoDB error): ${lock_result}. Exiting to avoid a concurrent sync."
    exit 1
  fi
}

release_lock() {
  python3 -c "
import boto3, os
ddb = boto3.client('dynamodb', region_name=os.environ['DYNAMODB_REGION'])
ddb.delete_item(
    TableName=os.environ['DYNAMODB_TABLE'],
    Key={'request_id': {'S': 'SYNC_LOCK'}},
)
" 2>&1 || true
}

acquire_lock
trap release_lock EXIT

SYNC_DIR="/data/sync"
FAILED_RPMS=""
TOTAL_SYNCED=0
TOTAL_FAILED=0

verify_gpg() {
  local rpm_file="$1"
  local result
  result=$(rpm -K "$rpm_file" 2>&1)
  if echo "$result" | grep -q "digests signatures OK"; then
    return 0
  fi

  # A digest proves file integrity, not signer identity. Reject unsigned RPMs,
  # unknown signing keys, and every other result that lacks a valid signature.
  FAILED_RPMS="${FAILED_RPMS}\n  ${rpm_file}: ${result}"
  TOTAL_FAILED=$((TOTAL_FAILED + 1))
  return 1
}

sync_repo() {
  local os_prefix="$1"
  local repo_id="$2"
  local repo_url="$3"
  local arch="${4:-x86_64}"

  # Include i686 (32-bit) packages for x86_64 repos when the workload needs
  # multilib. ARM64 repos do not carry i686.
  local arch_filter="${arch},noarch"
  if [[ "$arch" == "x86_64" ]]; then
    arch_filter="${arch},noarch,i686"
  fi

  echo ""
  echo "=== Syncing ${os_prefix}/${repo_id} (arch: ${arch_filter}) ==="

  local local_dir="${SYNC_DIR}/${os_prefix}/${repo_id}"
  if ! mkdir -p "${local_dir}" "${SYNC_DIR}/repos.d"; then
    echo "  ERROR: Could not create working directories for ${os_prefix}/${repo_id}"
    return 1
  fi

  cat > ${SYNC_DIR}/repos.d/frozen-sync-${os_prefix}-${repo_id}.repo <<EOF
[frozen-sync-${os_prefix}-${repo_id}]
name=Frozen Sync - ${os_prefix} ${repo_id}
baseurl=${repo_url}
enabled=1
gpgcheck=0
EOF

  echo "  Downloading packages..."
  dnf reposync \
    --repoid="frozen-sync-${os_prefix}-${repo_id}" \
    --setopt=reposdir=${SYNC_DIR}/repos.d \
    --setopt=cachedir=${SYNC_DIR}/cache \
    --download-metadata \
    --newest-only \
    --arch="${arch_filter}" \
    --download-path="${local_dir}/" \
    --norepopath \
    2>&1 | tail -5 || {
      echo "  ERROR: reposync failed for ${os_prefix}/${repo_id}"
      return 1
    }

  local rpm_count
  rpm_count=$(find "${local_dir}" -name "*.rpm" | wc -l)
  echo "  Downloaded: ${rpm_count} RPMs"

  if [[ $rpm_count -eq 0 ]]; then
    echo "  ERROR: Zero RPMs downloaded for ${os_prefix}/${repo_id}, skipping to protect production"
    return 1
  fi

  echo "  GPG verifying all ${rpm_count} RPMs..."
  local verified=0
  local rejected=0
  find "${local_dir}" -name "*.rpm" > /tmp/rpm_list.txt
  while read -r rpm; do
    if verify_gpg "$rpm"; then
      verified=$((verified + 1))
    else
      rm -f "$rpm"
      rejected=$((rejected + 1))
    fi
  done < /tmp/rpm_list.txt
  rm -f /tmp/rpm_list.txt

  echo "  GPG results: ${verified} verified, ${rejected} rejected"
  if [[ $rejected -gt 0 ]]; then
    echo "  ERROR: ${rejected} RPM(s) failed signature verification for ${os_prefix}/${repo_id}; refusing partial promotion"
    return 1
  fi
  if [[ $verified -eq 0 ]]; then
    echo "  ERROR: No RPM passed signature verification for ${os_prefix}/${repo_id}"
    return 1
  fi

  echo "  Generating repodata..."
  if ! createrepo_c "${local_dir}" --update 2>&1 | tail -3; then
    echo "  ERROR: createrepo_c failed for ${os_prefix}/${repo_id}; refusing promotion"
    return 1
  fi

  echo "  Uploading to staging..."
  if ! aws s3 sync "${local_dir}/" "s3://${S3_BUCKET}/staging/${os_prefix}/${repo_id}/" \
      --region "${S3_REGION}" --storage-class INTELLIGENT_TIERING --only-show-errors; then
    echo "  ERROR: Staging upload failed for ${os_prefix}/${repo_id}; refusing promotion"
    return 1
  fi

  echo "  Promoting staging to production..."
  if ! aws s3 sync "s3://${S3_BUCKET}/staging/${os_prefix}/${repo_id}/" \
      "s3://${S3_BUCKET}/${os_prefix}/${repo_id}/" \
      --region "${S3_REGION}" --storage-class INTELLIGENT_TIERING --delete --only-show-errors; then
    echo "  ERROR: Production promotion failed for ${os_prefix}/${repo_id}"
    return 1
  fi

  echo "  Cleaning up staging..."
  if ! aws s3 rm "s3://${S3_BUCKET}/staging/${os_prefix}/${repo_id}/" \
      --region "${S3_REGION}" --recursive --only-show-errors; then
    echo "  WARN: Could not remove staging objects for ${os_prefix}/${repo_id}"
  fi

  TOTAL_SYNCED=$((TOTAL_SYNCED + rpm_count - rejected))
  echo "  Done: ${os_prefix}/${repo_id}"
  rm -f "${SYNC_DIR}/repos.d/frozen-sync-${os_prefix}-${repo_id}.repo"
}

full_sync() {
  local sync_errors=0

  # UPSTREAM_REPOS_MAP derives from os_matrix (JSON: os_prefix -> repo_id -> url),
  # the same map the selective path uses, so the two sync modes cannot drift.
  local triples
  triples=$(python3 -c "
import json, os
m = json.loads(os.environ.get('UPSTREAM_REPOS_MAP', '{}'))
for osp in sorted(m):
    for rid in sorted(m[osp]):
        print(osp, rid, m[osp][rid])
")
  if [[ -z "${triples}" ]]; then
    echo "ERROR: UPSTREAM_REPOS_MAP is empty or unset; nothing to sync" >&2
    exit 1
  fi

  while read -r os_prefix repo_id repo_url; do
    sync_repo "${os_prefix}" "${repo_id}" "${repo_url}" "x86_64" || sync_errors=$((sync_errors + 1))
  done <<< "${triples}"

  if [[ $sync_errors -gt 0 ]]; then
    echo ""
    echo "  ERROR: ${sync_errors} repo(s) failed to sync; full sync is incomplete"
    TOTAL_FAILED=$((TOTAL_FAILED + sync_errors))
    return 1
  fi
}

selective_sync() {
  echo ""
  echo "=== SELECTIVE SYNC (REQUEST_ID: ${REQUEST_ID}) ==="

  local approved_file="/tmp/approved.json"
  local selective_errors=0
  echo "  Fetching approved package list from S3..."
  if ! aws s3 cp "s3://${S3_BUCKET}/requests/${REQUEST_ID}/approved.json" "${approved_file}" \
      --region "${S3_REGION}" 2>/dev/null; then
    echo "  ERROR: Could not fetch approved package list; refusing to sync without an approval artifact"
    return 1
  fi

  local approved_count
  approved_count=$(python3 -c "import json; print(len(json.load(open('${approved_file}'))))")
  echo "  Approved packages: ${approved_count}"
  if [[ "$approved_count" -eq 0 ]]; then
    echo "  No packages approved. Nothing to sync."
    return 0
  fi

  # Group approved NEVRAs by repo, download, GPG verify, then ADDITIVELY upload
  # (never --delete Packages/) and merge repodata.
  python3 -c "
import json
approved = json.load(open('${approved_file}'))
by_repo = {}
for entry in approved:
    parts = entry.split('/', 2)
    if len(parts) == 3:
        by_repo.setdefault(f'{parts[0]}/{parts[1]}', []).append(parts[2])
json.dump(by_repo, open('/tmp/approved_by_repo.json', 'w'))
print(f'Parsed {len(approved)} packages across {len(by_repo)} repos')
"

  while IFS= read -r repo_key; do
    local os_prefix="${repo_key%%/*}"
    local repo_id="${repo_key#*/}"
    local work_dir="${SYNC_DIR}/selective/${os_prefix}/${repo_id}"
    local arch="x86_64"
    [[ "$os_prefix" == *"-arm64"* ]] && arch="aarch64"
    local arch_filter="${arch},noarch"
    [[ "$arch" == "x86_64" ]] && arch_filter="${arch},noarch,i686"

    local repo_url
    repo_url=$(python3 -c "
import json, os
repos = json.loads(os.environ.get('UPSTREAM_REPOS_MAP', '{}'))
print(repos.get('${os_prefix}', {}).get('${repo_id}', ''))
" 2>/dev/null)
    if [[ -z "$repo_url" ]]; then
      echo "  ERROR: No upstream URL for ${os_prefix}/${repo_id}"
      selective_errors=$((selective_errors + 1))
      continue
    fi

    mkdir -p "${work_dir}" "${SYNC_DIR}/repos.d"
    cat > "${SYNC_DIR}/repos.d/selective-${os_prefix}-${repo_id}.repo" <<EOF
[selective-${os_prefix}-${repo_id}]
name=Selective Sync - ${os_prefix} ${repo_id}
baseurl=${repo_url}
enabled=1
gpgcheck=0
EOF

    local download_errors=0
    while IFS= read -r nevra; do
      if ! dnf download \
        --repoid="selective-${os_prefix}-${repo_id}" \
        --setopt=reposdir="${SYNC_DIR}/repos.d" \
        --setopt=cachedir="${SYNC_DIR}/cache" \
        --arch="${arch_filter}" \
        --downloaddir="${work_dir}/" \
        "${nevra}" 2>&1 | tail -2; then
        echo "    ERROR: Failed to download approved package ${nevra}"
        download_errors=$((download_errors + 1))
      fi
    done < <(python3 -c "
import json
by_repo = json.load(open('/tmp/approved_by_repo.json'))
for nevra in by_repo.get('${os_prefix}/${repo_id}', []):
    print(nevra)
")

    if [[ $download_errors -gt 0 ]]; then
      echo "  ERROR: ${download_errors} approved package(s) failed to download for ${os_prefix}/${repo_id}; refusing partial update"
      selective_errors=$((selective_errors + 1))
      rm -f "${SYNC_DIR}/repos.d/selective-${os_prefix}-${repo_id}.repo"
      rm -rf "${work_dir}"
      continue
    fi

    local verified=0
    local rejected=0
    find "${work_dir}" -name "*.rpm" > /tmp/sel_rpms.txt || true
    while read -r rpm; do
      if verify_gpg "$rpm"; then
        verified=$((verified + 1))
      else
        rm -f "$rpm"
        rejected=$((rejected + 1))
      fi
    done < /tmp/sel_rpms.txt
    rm -f /tmp/sel_rpms.txt
    if [[ $rejected -gt 0 || $verified -eq 0 ]]; then
      echo "  ERROR: Signature verification failed for ${os_prefix}/${repo_id} (${verified} verified, ${rejected} rejected); refusing partial update"
      selective_errors=$((selective_errors + 1))
      rm -f "${SYNC_DIR}/repos.d/selective-${os_prefix}-${repo_id}.repo"
      rm -rf "${work_dir}"
      continue
    fi

    # Additive upload (NO --delete on Packages/).
    if ! aws s3 sync "${work_dir}/" "s3://${S3_BUCKET}/${os_prefix}/${repo_id}/Packages/" \
        --region "${S3_REGION}" --storage-class INTELLIGENT_TIERING --only-show-errors; then
      echo "  ERROR: Package upload failed for ${os_prefix}/${repo_id}"
      return 1
    fi

    # Merge new repodata into the existing production repodata.
    local new_dir="/tmp/rd_new/${os_prefix}/${repo_id}"
    local old_dir="/tmp/rd_old/${os_prefix}/${repo_id}"
    local merged_dir="/tmp/rd_merged/${os_prefix}/${repo_id}"
    mkdir -p "${new_dir}/Packages" "${old_dir}" "${merged_dir}"
    cp "${work_dir}"/*.rpm "${new_dir}/Packages/" 2>/dev/null || true
    if ! createrepo_c "${new_dir}" 2>&1 | tail -3; then
      echo "  ERROR: createrepo_c failed for approved packages in ${os_prefix}/${repo_id}"
      return 1
    fi
    if ! aws s3 sync "s3://${S3_BUCKET}/${os_prefix}/${repo_id}/repodata/" "${old_dir}/repodata/" \
        --region "${S3_REGION}" --only-show-errors; then
      echo "  ERROR: Could not download existing repodata for ${os_prefix}/${repo_id}"
      return 1
    fi
    if [[ ! -d "${old_dir}/repodata" || ! -d "${new_dir}/repodata" ]]; then
      echo "  ERROR: Existing or new repository metadata is missing for ${os_prefix}/${repo_id}"
      return 1
    fi
    if ! mergerepo_c --repo "${old_dir}" --repo "${new_dir}" -o "${merged_dir}" 2>&1 | tail -3; then
      echo "  ERROR: mergerepo_c failed for ${os_prefix}/${repo_id}"
      return 1
    fi
    if [[ ! -d "${merged_dir}/repodata" ]]; then
      echo "  ERROR: Metadata merge produced no repodata for ${os_prefix}/${repo_id}"
      return 1
    fi
    if ! aws s3 sync "${merged_dir}/repodata/" "s3://${S3_BUCKET}/${os_prefix}/${repo_id}/repodata/" \
        --region "${S3_REGION}" --storage-class INTELLIGENT_TIERING --delete --only-show-errors; then
      echo "  ERROR: Repodata promotion failed for ${os_prefix}/${repo_id}"
      return 1
    fi
    rm -rf "${new_dir}" "${old_dir}" "${merged_dir}"
    TOTAL_SYNCED=$((TOTAL_SYNCED + verified))
    echo "  Done: ${os_prefix}/${repo_id} (+${verified} packages)"
    rm -f "${SYNC_DIR}/repos.d/selective-${os_prefix}-${repo_id}.repo"
  done < <(python3 -c "
import json
by_repo = json.load(open('/tmp/approved_by_repo.json'))
for k in sorted(by_repo.keys()):
    print(k)
")

  rm -f "${approved_file}" /tmp/approved_by_repo.json

  if [[ $selective_errors -gt 0 ]]; then
    echo "  ERROR: ${selective_errors} repository update(s) failed; selective sync is incomplete"
    TOTAL_FAILED=$((TOTAL_FAILED + selective_errors))
    return 1
  fi
}

main() {
  if [[ "${FULL_SYNC:-}" == "true" ]]; then
    if [[ "${BASELINE_APPROVED:-}" != "true" ]]; then
      echo "ERROR: FULL_SYNC requires BASELINE_APPROVED=true to acknowledge the operator-authorized initial baseline"
      exit 1
    fi
    full_sync
  elif [[ -n "${REQUEST_ID:-}" ]]; then
    selective_sync
  else
    echo "ERROR: Neither FULL_SYNC=true nor REQUEST_ID is set"
    exit 1
  fi

  # Package validation is informational. Manifest rebuild is handled by the
  # Manifest Updater Lambda via an EventBridge rule on ECS task stop.
  /app/validate_packages.sh || echo "  WARN: Package validation reported failures (informational)"

  echo ""
  echo "=== SYNC COMPLETE ==="
  echo "  Total RPMs synced: ${TOTAL_SYNCED}"
  echo "  Total GPG rejected: ${TOTAL_FAILED}"
  if [[ $TOTAL_FAILED -gt 0 ]]; then
    echo -e "  REJECTED RPMs:${FAILED_RPMS}"
    exit 1
  fi
}

main "$@"
