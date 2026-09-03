"""Frozen Repo Detector Lambda.

Monthly detection: compares upstream repos against the current S3 frozen state.
Categorizes findings as UPGRADES (newer version of an existing package) or
NEW (package not currently in the frozen repo). Always sends an SNS notification
(even when no changes are found).

Sanitized reference implementation. UPSTREAM_REPOS is supplied as an environment
variable (a JSON map of os_prefix -> repo_id -> upstream URL); nothing distro or
site specific is hardcoded here.
"""

import base64
import gzip
import json
import lzma
import os
import time
import urllib.parse
import urllib.request
import uuid

# Use defusedxml instead of the stdlib xml.etree parser. The stdlib parser is
# vulnerable to XXE (external entity) and XML-bomb (billion-laughs / quadratic
# blowup) attacks when fed untrusted input, and upstream repo metadata is
# fetched over the network. defusedxml.ElementTree exposes drop-in fromstring
# and iterparse that disable entity expansion and external DTD/entity loading.
# The Element objects returned are standard ElementTree Elements, so downstream
# .find / .findall / .remove / .clear behavior is unchanged.
from defusedxml.ElementTree import fromstring as _xml_fromstring
from defusedxml.ElementTree import iterparse as _xml_iterparse

import boto3

# Only remote HTTPS mirrors are permitted. Rejecting every other scheme closes
# the urlopen finding: file:// (local file read), ftp://, http:// (cleartext),
# and any custom/opaque scheme cannot be fetched.
ALLOWED_URL_SCHEMES = frozenset({"https"})


def _validate_url_scheme(url):
    """Reject any URL whose scheme is not in ALLOWED_URL_SCHEMES.

    Called before every urlopen so that a poisoned UPSTREAM_REPOS entry (e.g.
    file:///etc/passwd or a custom scheme) cannot be dereferenced.
    """
    scheme = urllib.parse.urlparse(url).scheme.lower()
    if scheme not in ALLOWED_URL_SCHEMES:
        raise ValueError(
            f"Refusing to fetch URL with disallowed scheme {scheme!r}: {url}. "
            f"Only {sorted(ALLOWED_URL_SCHEMES)} is permitted."
        )
    return url

DYNAMODB_TABLE = os.environ["DYNAMODB_TABLE"]
SNS_TOPIC_ARN = os.environ["SNS_TOPIC_ARN"]
TOKEN_KMS_KEY_ARN = os.environ["TOKEN_KMS_KEY_ARN"]
S3_BUCKET = os.environ["S3_BUCKET"]
APPLY_LAMBDA_URL = os.environ["APPLY_LAMBDA_URL"]
TOKEN_EXPIRY_HOURS = int(os.environ.get("TOKEN_EXPIRY_HOURS", "336"))
UPSTREAM_REPOS = json.loads(os.environ["UPSTREAM_REPOS"])

dynamodb = boto3.resource("dynamodb")
s3 = boto3.client("s3")
kms = boto3.client("kms")
sns = boto3.client("sns")

NS = {"rpm": "http://linux.duke.edu/metadata/common"}
NS_REPO = {"repo": "http://linux.duke.edu/metadata/repo"}


def _resolve_primary_url(base_url):
    """Download repomd.xml and extract the actual primary.xml.gz href.

    Repo metadata files use hash-prefixed names (e.g. 812dca7...-primary.xml.gz).
    The only stable entry point is repomd.xml, which lists all metadata locations.
    """
    repomd_url = base_url.rstrip("/") + "/repodata/repomd.xml"
    _validate_url_scheme(repomd_url)
    req = urllib.request.Request(repomd_url, headers={"User-Agent": "frozen-detector/2.0"})
    # nosemgrep: python.lang.security.audit.dynamic-urllib-use-detected.dynamic-urllib-use-detected -- URL scheme validated to https by _validate_url_scheme() above
    with urllib.request.urlopen(req, timeout=60) as resp:  # nosec B310 - scheme validated to https above
        repomd_xml = resp.read()
    root = _xml_fromstring(repomd_xml)
    for data_elem in root.findall("repo:data", NS_REPO):
        if data_elem.get("type") == "primary":
            location = data_elem.find("repo:location", NS_REPO)
            if location is not None:
                href = location.get("href")
                return base_url.rstrip("/") + "/" + href
    raise ValueError(f"No primary metadata found in {repomd_url}")


def _parse_primary_xml(base_url):
    """Resolve primary.xml.gz/.xz via repomd.xml, then stream-parse the package list.

    Uses iterparse plus streaming decompression to keep memory constant
    regardless of repo size. Supports gzip (.gz) and xz/lzma (.xz).
    Returns dict of {name.arch: {name, arch, epoch, version, release, nevra}}.
    """
    url = _resolve_primary_url(base_url)
    _validate_url_scheme(url)
    req = urllib.request.Request(url, headers={"User-Agent": "frozen-detector/2.0"})
    packages = {}

    # nosemgrep: python.lang.security.audit.dynamic-urllib-use-detected.dynamic-urllib-use-detected -- URL scheme validated to https by _validate_url_scheme() above
    with urllib.request.urlopen(req, timeout=300) as resp:  # nosec B310 - scheme validated to https above
        raw_data = resp.read()

    if url.endswith(".xz"):
        decompressed = lzma.decompress(raw_data)
    else:
        decompressed = gzip.decompress(raw_data)

    import io
    source = io.BytesIO(decompressed)
    del decompressed

    root = None
    context = _xml_iterparse(source, events=("start", "end"))

    for event, elem in context:
        if event == "start" and root is None:
            root = elem
        elif event == "end" and elem.tag == "{http://linux.duke.edu/metadata/common}package":
            name_el = elem.find("rpm:name", NS)
            arch_el = elem.find("rpm:arch", NS)
            ver_el = elem.find("rpm:version", NS)

            if name_el is not None and arch_el is not None and ver_el is not None:
                name = name_el.text
                arch = arch_el.text
                epoch = ver_el.get("epoch", "0")
                version = ver_el.get("ver")
                release = ver_el.get("rel")

                # Skip modular builds (release like 18.module_el8.10.0+3794+...).
                # AppStream primary.xml lists parallel builds per module stream,
                # which a plain version compare misreads as upgrades, and
                # dnf download refuses module NEVRAs outside an enabled stream
                # ("Exiting due to strict setting"), so the selective sync could
                # never deliver them. Module content updates arrive via full sync.
                if release and ".module_" in f".{release}":
                    if root is not None:
                        root.remove(elem)
                    continue

                key = f"{name}.{arch}"

                if key not in packages:
                    packages[key] = {
                        "name": name,
                        "arch": arch,
                        "epoch": epoch,
                        "version": version,
                        "release": release,
                        "nevra": f"{name}-{epoch}:{version}-{release}.{arch}",
                    }

            if root is not None:
                root.remove(elem)

    if root is not None:
        root.clear()

    return packages


def _get_manifest():
    """Load the current manifest from S3, or an empty dict if not found.

    Manifest format: {os_ver: {repo_id: {name.arch: {nevra, version, release, epoch}}}}
    """
    try:
        resp = s3.get_object(Bucket=S3_BUCKET, Key="manifest.json")
        return json.loads(resp["Body"].read())
    except s3.exceptions.NoSuchKey:
        # Genuinely no manifest yet (first run). An empty manifest here is
        # correct: everything upstream is legitimately "new".
        return {}
    except Exception as e:
        # Any OTHER error (throttle, access denied, timeout, corrupt JSON) must
        # NOT be swallowed. Returning {} would make every already-frozen package
        # look brand new and fire a spurious mass-approval request. Fail loud so
        # the run errors and retries instead of silently mis-detecting.
        raise RuntimeError(f"Failed to load manifest.json (not a NoSuchKey miss): {e}") from e


def _compare_versions(upstream_ver, upstream_rel, current_ver, current_rel):
    """Simple version comparison. Returns True if upstream is newer."""
    def _split_ver(v):
        import re
        return [int(x) if x.isdigit() else x for x in re.split(r'[.\-]', str(v))]

    def _safe_compare(a, b):
        """Compare two version lists safely, handling mixed int/str."""
        for x, y in zip(a, b):
            if type(x) != type(y):
                x, y = str(x), str(y)
            if x < y:
                return -1
            if x > y:
                return 1
        return len(a) - len(b)

    uv = _split_ver(upstream_ver)
    cv = _split_ver(current_ver)
    ver_cmp = _safe_compare(uv, cv)
    if ver_cmp != 0:
        return ver_cmp > 0
    ur = _split_ver(upstream_rel)
    cr = _split_ver(current_rel)
    return _safe_compare(ur, cr) > 0


def _generate_token(request_id, expires_at):
    """Encrypt request_id plus expiry with the KMS symmetric key as the token."""
    plaintext = json.dumps({"request_id": request_id, "expires_at": expires_at}).encode()
    resp = kms.encrypt(
        KeyId=TOKEN_KMS_KEY_ARN,
        Plaintext=plaintext,
        EncryptionContext={"purpose": "frozen-repo-approval"},
    )
    return base64.urlsafe_b64encode(resp["CiphertextBlob"]).decode()


def lambda_handler(event, context):
    manifest = _get_manifest()
    now = int(time.time())
    expires_at = now + (TOKEN_EXPIRY_HOURS * 3600)

    candidates = {}
    total_upgrades = 0
    total_new = 0

    for os_ver, repos in UPSTREAM_REPOS.items():
        candidates[os_ver] = {}
        for repo_name, url in repos.items():
            try:
                upstream_pkgs = _parse_primary_xml(url)
            except Exception as e:
                print(f"WARN: Failed to fetch {os_ver}/{repo_name}: {e}")
                candidates[os_ver][repo_name] = {"upgrades": [], "new": [], "error": str(e)}
                continue

            current_pkgs = manifest.get(os_ver, {}).get(repo_name, {})
            upgrades = []
            new_packages = []

            for key, upstream_info in upstream_pkgs.items():
                if key in current_pkgs:
                    # Package exists in the frozen repo. Check if upstream is newer.
                    current_info = current_pkgs[key]
                    if _compare_versions(
                        upstream_info["version"], upstream_info["release"],
                        current_info.get("version", "0"), current_info.get("release", "0"),
                    ):
                        upgrades.append({
                            "nevra": upstream_info["nevra"],
                            "name": upstream_info["name"],
                            "arch": upstream_info["arch"],
                            "old_version": f"{current_info.get('epoch', '0')}:{current_info.get('version', '?')}-{current_info.get('release', '?')}",
                            "new_version": f"{upstream_info['epoch']}:{upstream_info['version']}-{upstream_info['release']}",
                        })
                else:
                    # Package does NOT exist in the frozen repo. Brand new.
                    new_packages.append({
                        "nevra": upstream_info["nevra"],
                        "name": upstream_info["name"],
                        "arch": upstream_info["arch"],
                        "version": f"{upstream_info['epoch']}:{upstream_info['version']}-{upstream_info['release']}",
                    })

            candidates[os_ver][repo_name] = {
                "upgrades": sorted(upgrades, key=lambda x: x["name"]),
                "new": sorted(new_packages, key=lambda x: x["name"]),
            }
            total_upgrades += len(upgrades)
            total_new += len(new_packages)

    # Always send a notification (even if nothing found)
    total_changes = total_upgrades + total_new

    if total_changes == 0:
        repos_checked = "\n".join(
            f"  - {os_ver}/{repo}"
            for os_ver, repos in UPSTREAM_REPOS.items()
            for repo in repos
        )
        sns.publish(
            TopicArn=SNS_TOPIC_ARN,
            Subject="[FrozenRepo] Monthly package check - no updates available",
            Message=(
                "No new or updated packages detected across any upstream repositories.\n\n"
                f"Repos checked:\n{repos_checked}\n\n"
                "No action required. The frozen repo is up to date.\n"
            ),
        )
        print("No changes detected. All-clear notification sent.")
        return {"statusCode": 200, "body": "No updates"}

    # Changes found. Create an approval request.
    request_id = str(uuid.uuid4())
    table = dynamodb.Table(DYNAMODB_TABLE)

    packages_key = f"requests/{request_id}/candidates.json"
    s3.put_object(
        Bucket=S3_BUCKET,
        Key=packages_key,
        Body=json.dumps(candidates).encode(),
        ContentType="application/json",
    )

    table.put_item(Item={
        "request_id": request_id,
        "status": "pending",
        "created_at": now,
        "expires_at": expires_at,
        "os_versions": list(UPSTREAM_REPOS.keys()),
        "packages_s3_key": packages_key,
        "total_upgrades": total_upgrades,
        "total_new": total_new,
        "total_changes": total_changes,
    })

    token = _generate_token(request_id, expires_at)
    review_url = f"{APPLY_LAMBDA_URL}?id={request_id}&token={token}"

    summary_lines = [
        f"Upgrades available: {total_upgrades}",
        f"New packages available: {total_new}",
        f"Total: {total_changes}\n",
    ]
    for os_ver, repos in candidates.items():
        for repo_name, data in repos.items():
            if data.get("error"):
                summary_lines.append(f"  WARNING: {os_ver}/{repo_name}: FETCH FAILED ({data['error'][:50]})")
            elif data["upgrades"] or data["new"]:
                parts = []
                if data["upgrades"]:
                    parts.append(f"{len(data['upgrades'])} upgrades")
                if data["new"]:
                    parts.append(f"{len(data['new'])} new")
                summary_lines.append(f"  {os_ver}/{repo_name}: {', '.join(parts)}")

    sns.publish(
        TopicArn=SNS_TOPIC_ARN,
        Subject=f"[FrozenRepo] {total_upgrades} upgrades + {total_new} new packages - review required",
        Message=(
            "\n".join(summary_lines)
            + f"\n\nReview and approve:\n{review_url}\n\n"
            f"Token expires in {TOKEN_EXPIRY_HOURS // 24} days.\n"
            "\nNote: Upgrades are pre-selected for approval. New packages require explicit selection.\n"
            "\nPackage update policy:\n\n"
            " - OS versions are pinned as a policy to ensure deterministic, reproducible builds.\n"
            " - Pinned (frozen) OS versions do not receive baseos/appstream updates.\n"
            " - Configure which prefixes are pinned versus tracked in your UPSTREAM_REPOS map.\n"
        ),
    )

    print(f"Detection complete: {total_upgrades} upgrades, {total_new} new, request_id={request_id}")
    return {
        "statusCode": 200,
        "body": json.dumps({
            "request_id": request_id,
            "total_upgrades": total_upgrades,
            "total_new": total_new,
        }),
    }
