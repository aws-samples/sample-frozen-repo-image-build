"""Frozen Repo Manifest Updater Lambda.

Triggered by EventBridge when the ECS sync task stops. Rebuilds manifest.json
from the current S3 repodata state (repomd.xml resolution for hash-prefixed
primary.xml.gz/.xz files). Archives the previous manifest before overwriting.

Sanitized reference implementation. The scan matrix arrives via the
REPOS_TO_SCAN env var, derived from the os_matrix registry by Terraform.
"""

import gzip
import io
import json
import lzma
import os
from datetime import datetime, timezone

# Use defusedxml instead of the stdlib xml.etree parser. The stdlib parser is
# vulnerable to XML External Entity (XXE) attacks and entity-expansion ("XML
# bomb") denial of service when handed untrusted XML, and repo metadata is
# fetched over the network. defusedxml exposes drop-in fromstring and iterparse.
from defusedxml.ElementTree import fromstring as _xml_fromstring
from defusedxml.ElementTree import iterparse as _xml_iterparse

import boto3

S3_BUCKET = os.environ["S3_BUCKET"]
S3_REGION = os.environ["S3_REGION"]

s3 = boto3.client("s3", region_name=S3_REGION)

NS_RPM = {"rpm": "http://linux.duke.edu/metadata/common"}
NS_REPO = {"repo": "http://linux.duke.edu/metadata/repo"}

# {os_prefix: [repo_id, ...]} to rescan, injected by Terraform from the single
# os_matrix registry (config.hcl) so this consumer cannot drift from the store
# layout when an OS is onboarded or a component renamed.
REPOS_TO_SCAN = json.loads(os.environ["REPOS_TO_SCAN"])


def _get_primary_key(os_ver, repo_id):
    """Resolve the hash-prefixed primary.xml.gz/.xz key from repomd.xml in S3."""
    repomd_key = f"{os_ver}/{repo_id}/repodata/repomd.xml"
    try:
        resp = s3.get_object(Bucket=S3_BUCKET, Key=repomd_key)
    except s3.exceptions.NoSuchKey:
        return None

    root = _xml_fromstring(resp["Body"].read())
    for data_elem in root.findall("repo:data", NS_REPO):
        if data_elem.get("type") == "primary":
            location = data_elem.find("repo:location", NS_REPO)
            if location is not None:
                href = location.get("href")
                return f"{os_ver}/{repo_id}/{href}"
    return None


def _parse_packages(primary_key):
    """Download and parse primary.xml.gz/.xz from S3, return package dict."""
    resp = s3.get_object(Bucket=S3_BUCKET, Key=primary_key)
    raw_data = resp["Body"].read()

    if primary_key.endswith(".xz"):
        source = lzma.open(io.BytesIO(raw_data), mode="rb")
    else:
        source = io.BytesIO(gzip.decompress(raw_data))

    packages = {}
    root = None
    context = _xml_iterparse(source, events=("start", "end"))

    for event, elem in context:
        if event == "start" and root is None:
            root = elem
        elif event == "end" and elem.tag == "{http://linux.duke.edu/metadata/common}package":
            name_el = elem.find("rpm:name", NS_RPM)
            arch_el = elem.find("rpm:arch", NS_RPM)
            ver_el = elem.find("rpm:version", NS_RPM)

            if name_el is not None and arch_el is not None and ver_el is not None:
                name = name_el.text
                arch = arch_el.text
                epoch = ver_el.get("epoch", "0")
                version = ver_el.get("ver")
                release = ver_el.get("rel")
                key = f"{name}.{arch}"
                packages[key] = {
                    "nevra": f"{name}-{epoch}:{version}-{release}.{arch}",
                    "name": name,
                    "arch": arch,
                    "epoch": epoch,
                    "version": version,
                    "release": release,
                }

            if root is not None:
                root.remove(elem)

    if root is not None:
        root.clear()
    if hasattr(source, "close"):
        source.close()

    return packages


def lambda_handler(event, context):
    print(f"Manifest update triggered. Event: {json.dumps(event, default=str)[:500]}")

    manifest = {}
    total = 0

    for os_ver, repo_list in REPOS_TO_SCAN.items():
        manifest[os_ver] = {}
        for repo_id in repo_list:
            primary_key = _get_primary_key(os_ver, repo_id)
            if not primary_key:
                print(f"  WARN: {os_ver}/{repo_id}: no repomd.xml or no primary entry")
                manifest[os_ver][repo_id] = {}
                continue

            try:
                packages = _parse_packages(primary_key)
                manifest[os_ver][repo_id] = packages
                total += len(packages)
                print(f"  {os_ver}/{repo_id}: {len(packages)} packages")
            except Exception as e:
                print(f"  ERROR: {os_ver}/{repo_id}: {e}")
                manifest[os_ver][repo_id] = {}

    # Archive existing manifest
    timestamp = datetime.now(timezone.utc).strftime("%Y-%m-%d_%H-%M")
    try:
        existing = s3.get_object(Bucket=S3_BUCKET, Key="manifest.json")
        s3.put_object(
            Bucket=S3_BUCKET,
            Key=f"manifests/manifest-{timestamp}.json",
            Body=existing["Body"].read(),
            ContentType="application/json",
            StorageClass="INTELLIGENT_TIERING",
        )
        print(f"  Archived previous manifest to manifests/manifest-{timestamp}.json")
    except s3.exceptions.NoSuchKey:
        print("  No previous manifest to archive (first run)")
    except Exception as e:
        print(f"  WARN: Could not archive previous manifest: {e}")

    # Write new manifest
    manifest_body = json.dumps(manifest, separators=(",", ":")).encode()
    s3.put_object(
        Bucket=S3_BUCKET,
        Key="manifest.json",
        Body=manifest_body,
        ContentType="application/json",
        StorageClass="INTELLIGENT_TIERING",
    )

    print(f"  Manifest written: {total} total packages across {len(manifest)} OS versions")
    return {"statusCode": 200, "body": f"Manifest updated: {total} packages"}
