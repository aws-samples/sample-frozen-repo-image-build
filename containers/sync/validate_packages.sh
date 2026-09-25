#!/bin/bash
set -euo pipefail

# Package-list validation (informational only): after a sync, confirm each curated
# package list resolves against the local repo tree. Point PKG_LISTS at the lists.

SYNC_DIR="${SYNC_DIR:-/data/sync}"
# Vendor packages installed from direct URLs (not from the frozen repos) are skipped.
KNOWN_VENDOR_PACKAGES="amazon-cloudwatch-agent|amazon-ssm-agent|gpg-pubkey"
FAILURES=0

echo "=== Package List Validation ==="

# validate_list <pkg_list_file> <os_prefix> <repo_ids...>
validate_list() {
  local pkg_list_file="$1"; local os_prefix="$2"; local repo_names="$3"

  if [[ ! -f "$pkg_list_file" ]]; then
    echo "  SKIP: $pkg_list_file not found"
    return 0
  fi

  local total; total=$(grep -cve '^\s*$' "$pkg_list_file" || true)
  echo "  Checking ${total} packages from $(basename "$pkg_list_file") against ${os_prefix}/ ..."

  # Build a repo config from the local sync directories.
  local repo_conf="/tmp/validate-${os_prefix}.repo"; : > "$repo_conf"
  local repos_found=0
  for repo in $repo_names; do
    local repo_path="${SYNC_DIR}/${os_prefix}/${repo}"
    if [[ -d "$repo_path/repodata" ]]; then
      cat >> "$repo_conf" <<EOF
[validate-${os_prefix}-${repo}]
name=Validate ${os_prefix} ${repo}
baseurl=file://${repo_path}
enabled=1
gpgcheck=0

EOF
      repos_found=$((repos_found + 1))
    fi
  done

  if [[ $repos_found -eq 0 ]]; then
    echo "  SKIP: no local repos with repodata for ${os_prefix}/ (selective sync does not download full repos)"
    return 0
  fi

  local missing_file="/tmp/missing-${os_prefix}.txt"; : > "$missing_file"

  while IFS= read -r pkg; do
    # Trim whitespace; skip blanks and comment lines.
    pkg="${pkg#"${pkg%%[![:space:]]*}"}"; pkg="${pkg%"${pkg##*[![:space:]]}"}"
    [[ -z "$pkg" ]] && continue
    [[ "$pkg" == \#* ]] && continue
    [[ "$pkg" == gpg-pubkey* ]] && continue

    # Extract name(.arch) from either 'name.arch' or full NEVRA 'name-ver-rel.arch'.
    local query_pkg pkg_name
    if [[ "$pkg" == *.i686 || "$pkg" == *.x86_64 || "$pkg" == *.noarch || "$pkg" == *.aarch64 ]]; then
      local arch="${pkg##*.}"; local name_part="${pkg%.*}"
      local last="${name_part##*-}"
      if echo "$last" | grep -qE '(el[0-9]|fc[0-9]|\.module)'; then
        local without_rel="${name_part%-*}"; pkg_name="${without_rel%-*}"
      else
        pkg_name="$name_part"
      fi
      query_pkg="${pkg_name}.${arch}"
    else
      query_pkg="$pkg"; pkg_name="${pkg%%.*}"
    fi

    echo "$pkg_name" | grep -qE "^(${KNOWN_VENDOR_PACKAGES})$" && continue

    if ! dnf repoquery --quiet --disablerepo='*' \
        --setopt="reposdir=/dev/null" \
        --setopt="cachedir=/tmp/dnf-cache" \
        --config="$repo_conf" \
        "$query_pkg" 2>/dev/null | grep -q .; then
      echo "$pkg" >> "$missing_file"
    fi
  done < "$pkg_list_file"

  local missing_count; missing_count=$(grep -cve '^\s*$' "$missing_file" || true)
  if [[ $missing_count -gt 0 ]]; then
    echo "  WARN: ${missing_count} packages NOT FOUND in ${os_prefix}/:"
    head -20 "$missing_file" | sed 's/^/    /'
    [[ $missing_count -gt 20 ]] && echo "    ... and $((missing_count - 20)) more"
    FAILURES=$((FAILURES + missing_count))
  else
    echo "  PASS: all packages resolvable from ${os_prefix}/"
  fi
  rm -f "$repo_conf"
}

# PKG_LISTS is a space-separated set of "list_file:os_prefix:repo1,repo2,..." entries.
# Example: PKG_LISTS="/app/custom_packages_alma810.txt:alma810:baseos,appstream,epel"
for entry in ${PKG_LISTS:-}; do
  IFS=':' read -r list osp repos <<< "$entry"
  validate_list "$list" "$osp" "$(echo "$repos" | tr ',' ' ')"
done

echo ""
if [[ $FAILURES -gt 0 ]]; then
  echo "=== VALIDATION: ${FAILURES} packages unresolvable (informational) ==="
  exit 1
else
  echo "=== VALIDATION PASSED ==="
  exit 0
fi
