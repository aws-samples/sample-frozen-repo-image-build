"""Frozen Repo Approver (apply) Lambda (Function URL).

GET:  Validate the KMS-signed token, render an HTML review page with two sections:
      - UPGRADES (pre-checked): newer versions of existing packages
      - NEW PACKAGES (unchecked): packages not yet in the frozen repo
POST: Re-validate the token, update DynamoDB, trigger the ECS sync task.

Sanitized reference implementation. The Function URL is auth_type NONE (public);
security lives entirely in the app-layer KMS token check below. If you need a
stricter posture, front this with AWS_IAM auth or an authorizer instead.
"""

import base64
import html
import json
import os
import time
import urllib.parse

import boto3

DYNAMODB_TABLE = os.environ["DYNAMODB_TABLE"]
TOKEN_KMS_KEY_ARN = os.environ["TOKEN_KMS_KEY_ARN"]
ECS_CLUSTER = os.environ["ECS_CLUSTER"]
ECS_TASK_FAMILY = os.environ["ECS_TASK_FAMILY"]
ECS_SUBNETS = os.environ["ECS_SUBNETS"].split(",")
ECS_SECURITY_GROUP = os.environ["ECS_SECURITY_GROUP"]
SNS_TOPIC_ARN = os.environ["SNS_TOPIC_ARN"]
S3_BUCKET = os.environ["S3_BUCKET"]

dynamodb = boto3.resource("dynamodb")
kms = boto3.client("kms")
ecs = boto3.client("ecs")
sns = boto3.client("sns")
s3 = boto3.client("s3")


def _html(status_code, body):
    return {
        "statusCode": status_code,
        "headers": {"Content-Type": "text/html; charset=utf-8"},
        "body": body,
    }


def _page(title, content):
    return f"""<!DOCTYPE html>
<html><head><meta charset="utf-8"><title>{title}</title>
<style>
body{{font-family:system-ui,-apple-system,sans-serif;max-width:1000px;margin:2em auto;padding:0 1.5em;color:#1a1a1a}}
h1{{color:#1565c0;border-bottom:2px solid #1565c0;padding-bottom:0.3em}}
h2{{margin-top:2em;color:#333;border-bottom:1px solid #ddd;padding-bottom:0.3em}}
h3{{margin-top:1.5em;color:#555;font-size:1em}}
.section-upgrades{{background:#e8f5e9;border-left:4px solid #2e7d32;padding:1em;margin:1em 0;border-radius:4px}}
.section-new{{background:#fff3e0;border-left:4px solid #ef6c00;padding:1em;margin:1em 0;border-radius:4px}}
.info{{background:#e3f2fd;padding:1em;border-radius:4px;margin:1em 0}}
.stats{{display:flex;gap:1em;margin:1em 0}}
.stat{{background:#f5f5f5;padding:0.8em 1.2em;border-radius:4px;text-align:center}}
.stat-number{{font-size:1.5em;font-weight:bold;color:#1565c0}}
.stat-label{{font-size:0.85em;color:#666}}
label{{display:block;padding:3px 0;font-size:0.9em}}
label:hover{{background:#f0f0f0}}
.version-change{{color:#666;font-size:0.85em;margin-left:0.5em}}
.old-ver{{text-decoration:line-through;color:#999}}
.new-ver{{color:#2e7d32;font-weight:bold}}
.badge{{display:inline-block;font-size:0.7em;padding:1px 5px;border-radius:3px;margin-left:0.5em;vertical-align:middle}}
.badge-new{{background:#fff3e0;color:#e65100}}
button{{margin:1em 0.5em 1em 0;padding:0.7em 1.8em;font-size:1em;cursor:pointer;border:none;border-radius:4px}}
.approve{{background:#2e7d32;color:#fff}}
.approve:hover{{background:#1b5e20}}
.reject{{background:#c62828;color:#fff}}
.reject:hover{{background:#b71c1c}}
.btn-group{{margin:1.5em 0;padding-top:1em;border-top:2px solid #ddd}}
.select-controls{{margin:0.5em 0}}
.select-controls button{{font-size:0.85em;padding:0.4em 0.8em;background:#e0e0e0;color:#333}}
.select-controls button:hover{{background:#bdbdbd}}
</style>
</head><body><h1>{title}</h1>{content}</body></html>"""


def _verify_token(token_b64):
    """Decrypt the KMS token, verify expiry, return payload or None."""
    try:
        ciphertext = base64.urlsafe_b64decode(token_b64)
        resp = kms.decrypt(
            CiphertextBlob=ciphertext,
            EncryptionContext={"purpose": "frozen-repo-approval"},
        )
        payload = json.loads(resp["Plaintext"])
        if payload.get("expires_at", 0) < int(time.time()):
            return None
        return payload
    except Exception:
        return None


def _get_request(request_id):
    table = dynamodb.Table(DYNAMODB_TABLE)
    resp = table.get_item(Key={"request_id": request_id})
    return resp.get("Item")


def _render_review_page(request_id, token, item):
    """Render HTML with two sections: upgrades (checked) and new packages (unchecked)."""
    packages_key = item.get("packages_s3_key")
    resp = s3.get_object(Bucket=S3_BUCKET, Key=packages_key)
    packages = json.loads(resp["Body"].read())
    total_upgrades = int(item.get("total_upgrades", 0))
    total_new = int(item.get("total_new", 0))

    upgrade_rows = []
    new_rows = []

    for os_ver in sorted(packages.keys()):
        repos = packages[os_ver]
        for repo_name in sorted(repos.keys()):
            data = repos[repo_name]
            if isinstance(data, list):
                continue

            upgrades = data.get("upgrades", [])
            if upgrades:
                group_id = f"upgrade-{os_ver}-{repo_name}"
                upgrade_rows.append(f'<h3>{html.escape(os_ver)} / {html.escape(repo_name)} ({len(upgrades)} upgrades)</h3>')
                upgrade_rows.append(
                    f'<div class="select-controls">'
                    f'<button type="button" onclick="toggleGroup(\'{group_id}\', true)">Select All</button> '
                    f'<button type="button" onclick="toggleGroup(\'{group_id}\', false)">Deselect All</button>'
                    f'</div>'
                )
                for pkg in upgrades:
                    safe_name = html.escape(pkg["name"])
                    safe_value = html.escape(f'{os_ver}/{repo_name}/{pkg["nevra"]}', quote=True)
                    old_ver = html.escape(str(pkg.get("old_version", "?")))
                    new_ver = html.escape(str(pkg.get("new_version", "?")))
                    upgrade_rows.append(
                        f'<label><input type="checkbox" name="pkg" '
                        f'value="{safe_value}" '
                        f'class="{group_id}" checked> '
                        f'<strong>{safe_name}</strong>'
                        f'<span class="version-change">'
                        f'<span class="old-ver">{old_ver}</span> &rarr; '
                        f'<span class="new-ver">{new_ver}</span>'
                        f'</span></label>'
                    )

            new_pkgs = data.get("new", [])
            if new_pkgs:
                group_id = f"new-{os_ver}-{repo_name}"
                new_rows.append(f'<h3>{html.escape(os_ver)} / {html.escape(repo_name)} ({len(new_pkgs)} new packages)</h3>')
                new_rows.append(
                    f'<div class="select-controls">'
                    f'<button type="button" onclick="toggleGroup(\'{group_id}\', true)">Select All</button> '
                    f'<button type="button" onclick="toggleGroup(\'{group_id}\', false)">Deselect All</button>'
                    f'</div>'
                )
                for pkg in new_pkgs[:500]:
                    safe_name = html.escape(pkg["name"])
                    safe_value = html.escape(f'{os_ver}/{repo_name}/{pkg["nevra"]}', quote=True)
                    ver = html.escape(str(pkg.get("version", "?")))
                    new_rows.append(
                        f'<label><input type="checkbox" name="pkg" '
                        f'value="{safe_value}" '
                        f'class="{group_id}"> '
                        f'<strong>{safe_name}</strong>'
                        f'<span class="version-change">{ver}</span>'
                        f'<span class="badge badge-new">NEW</span></label>'
                    )
                if len(new_pkgs) > 500:
                    new_rows.append(f'<p><em>... and {len(new_pkgs) - 500} more (use Select All to include)</em></p>')
                    for pkg in new_pkgs[500:]:
                        safe_value = html.escape(f'{os_ver}/{repo_name}/{pkg["nevra"]}', quote=True)
                        new_rows.append(
                            f'<input type="hidden" name="pkg_hidden" '
                            f'value="{safe_value}" '
                            f'data-group="{group_id}">'
                        )

    stats_html = f"""
<div class="stats">
  <div class="stat"><div class="stat-number">{total_upgrades}</div><div class="stat-label">Upgrades Available</div></div>
  <div class="stat"><div class="stat-number">{total_new}</div><div class="stat-label">New Packages</div></div>
  <div class="stat"><div class="stat-number">{total_upgrades + total_new}</div><div class="stat-label">Total Changes</div></div>
</div>"""

    upgrades_html = ""
    if upgrade_rows:
        upgrades_html = f"""
<div class="section-upgrades">
<h2>Upgrades Available (newer versions of existing packages)</h2>
<p>These are pre-selected for approval. Deselect any you want to skip.</p>
{"".join(upgrade_rows)}
</div>"""

    new_html = ""
    if new_rows:
        new_html = f"""
<div class="section-new">
<h2>New Packages (not currently in the frozen repo)</h2>
<p>These are <strong>not selected</strong> by default. Check the ones you want to add.</p>
{"".join(new_rows)}
</div>"""

    content = f"""
<div class="info">Monthly package detection has completed. Review the changes below and approve or reject.</div>
{stats_html}
<form method="POST" action="?id={request_id}&token={token}">
<input type="hidden" name="request_id" value="{request_id}">
<input type="hidden" name="token" value="{token}">
{upgrades_html}
{new_html}
<div class="btn-group">
<button type="submit" name="action" value="approve" class="approve">Approve Selected</button>
<button type="submit" name="action" value="reject" class="reject">Reject All</button>
</div>
</form>
<script>
function toggleGroup(groupClass, state) {{
  document.querySelectorAll('input.' + groupClass).forEach(cb => cb.checked = state);
  document.querySelectorAll('input[data-group="' + groupClass + '"]').forEach(h => {{
    if (state) {{ h.name = 'pkg'; }} else {{ h.name = 'pkg_hidden'; }}
  }});
}}
</script>"""
    return _page("Frozen Repo - Package Review", content)


def _handle_get(params):
    request_id = params.get("id", [""])[0]
    token = params.get("token", [""])[0]

    if not request_id or not token:
        return _html(400, _page("Error", "<p>Missing request ID or token.</p>"))

    payload = _verify_token(token)
    if not payload:
        return _html(403, _page("Token Expired",
            "<p>The review token is invalid or has expired. "
            "Please wait for the next monthly detection cycle or ask an admin to trigger a new detection.</p>"))

    if payload.get("request_id") != request_id:
        return _html(403, _page("Token Mismatch", "<p>Token does not match this request.</p>"))

    item = _get_request(request_id)
    if not item:
        return _html(404, _page("Not Found", "<p>Request not found.</p>"))

    if item.get("status") != "pending":
        status = item.get("status", "unknown")
        return _html(200, _page("Already Processed",
            f"<p>This request was already <strong>{status}</strong>.</p>"
            f"<p>Processed at: {item.get('approved_at') or item.get('rejected_at', 'N/A')}</p>"))

    return _html(200, _render_review_page(request_id, token, item))


def _handle_post(body):
    parsed = urllib.parse.parse_qs(body)
    request_id = parsed.get("request_id", [""])[0]
    token = parsed.get("token", [""])[0]
    action = parsed.get("action", [""])[0]

    if not request_id or not token:
        return _html(400, _page("Error", "<p>Missing parameters.</p>"))

    payload = _verify_token(token)
    if not payload:
        return _html(403, _page("Token Expired", "<p>The token is invalid or expired.</p>"))

    if payload.get("request_id") != request_id:
        return _html(403, _page("Token Mismatch", "<p>Token does not match this request.</p>"))

    item = _get_request(request_id)
    if not item or item.get("status") != "pending":
        return _html(200, _page("Already Processed", "<p>This request was already processed.</p>"))

    table = dynamodb.Table(DYNAMODB_TABLE)
    now = int(time.time())

    if action == "reject":
        try:
            table.update_item(
                Key={"request_id": request_id},
                UpdateExpression="SET #s = :s, rejected_at = :t",
                ConditionExpression="#s = :pending",
                ExpressionAttributeNames={"#s": "status"},
                ExpressionAttributeValues={":s": "rejected", ":t": now, ":pending": "pending"},
            )
        except dynamodb.meta.client.exceptions.ConditionalCheckFailedException:
            return _html(200, _page("Already Processed", "<p>This request was already processed.</p>"))

        sns.publish(
            TopicArn=SNS_TOPIC_ARN,
            Subject="[FrozenRepo] Package update REJECTED",
            Message=f"Request {request_id} was rejected. No packages will be synced.",
        )
        return _html(200, _page("Rejected",
            "<p>All packages rejected. No sync will occur.</p>"
            "<p>The team has been notified.</p>"))

    # Approve. Collect selected packages.
    selected = parsed.get("pkg", [])

    if not selected:
        return _html(400, _page("No Packages Selected",
            "<p>No packages were selected for approval. "
            "Please go back and check at least one package, or click Reject All.</p>"))

    approved_key = f"requests/{request_id}/approved.json"
    s3.put_object(
        Bucket=S3_BUCKET,
        Key=approved_key,
        Body=json.dumps(selected).encode(),
        ContentType="application/json",
    )

    try:
        table.update_item(
            Key={"request_id": request_id},
            UpdateExpression="SET #s = :s, approved_at = :t, approved_s3_key = :k, approved_count = :c",
            ConditionExpression="#s = :pending",
            ExpressionAttributeNames={"#s": "status"},
            ExpressionAttributeValues={
                ":s": "approved",
                ":t": now,
                ":k": approved_key,
                ":c": len(selected),
                ":pending": "pending",
            },
        )
    except dynamodb.meta.client.exceptions.ConditionalCheckFailedException:
        return _html(200, _page("Already Processed", "<p>This request was already processed.</p>"))

    # Trigger the ECS sync task for the approved package set.
    try:
        ecs.run_task(
            cluster=ECS_CLUSTER,
            taskDefinition=ECS_TASK_FAMILY,
            launchType="FARGATE",
            networkConfiguration={
                "awsvpcConfiguration": {
                    "subnets": ECS_SUBNETS,
                    "securityGroups": [ECS_SECURITY_GROUP],
                    "assignPublicIp": "DISABLED",
                }
            },
            overrides={
                "containerOverrides": [{
                    "name": "sync",
                    "environment": [
                        {"name": "REQUEST_ID", "value": request_id},
                    ],
                }]
            },
        )
    except Exception as e:
        print(f"ERROR: Failed to trigger ECS task: {e}")
        # Compensating rollback: the status was already flipped to "approved"
        # above, but the sync task never started. Roll it back to "pending" so
        # the request stays retryable instead of being permanently stuck
        # "approved" with no sync (the single-use gate would otherwise block any
        # retry). Guarded on the row still being "approved" so we never clobber
        # a state a concurrent request legitimately advanced.
        try:
            table.update_item(
                Key={"request_id": request_id},
                UpdateExpression="SET #s = :pending REMOVE approved_at, approved_s3_key, approved_count",
                ConditionExpression="#s = :approved",
                ExpressionAttributeNames={"#s": "status"},
                ExpressionAttributeValues={":pending": "pending", ":approved": "approved"},
            )
        except dynamodb.meta.client.exceptions.ConditionalCheckFailedException:
            pass
        sns.publish(
            TopicArn=SNS_TOPIC_ARN,
            Subject="[FrozenRepo] WARN: Approval rolled back, ECS sync trigger failed",
            Message=f"Request {request_id} approval ({len(selected)} packages) was rolled back to pending because ECS RunTask failed: {e}. Re-open the review link to retry.",
        )
        return _html(500, _page("Sync Trigger Failed",
            "<p>The sync task failed to start, so the approval was rolled back. "
            "The request is pending again, re-open the review link to retry. The team has been notified.</p>"))

    sns.publish(
        TopicArn=SNS_TOPIC_ARN,
        Subject=f"[FrozenRepo] {len(selected)} packages approved - sync started",
        Message=f"Request {request_id}: {len(selected)} packages approved. ECS sync task triggered.",
    )

    return _html(200, _page("Approved",
        f"<p><strong>{len(selected)} packages</strong> approved and sync task started.</p>"
        f"<p>You will receive an email notification when the sync completes.</p>"
        f"<p><em>Request ID: {request_id}</em></p>"))


def lambda_handler(event, context):
    method = event.get("requestContext", {}).get("http", {}).get("method", "GET")

    if method == "GET":
        qs = event.get("rawQueryString", "")
        params = urllib.parse.parse_qs(qs)
        return _handle_get(params)

    if method == "POST":
        body = event.get("body", "")
        if event.get("isBase64Encoded"):
            body = base64.b64decode(body).decode()
        return _handle_post(body)

    return _html(405, _page("Method Not Allowed", "<p>Use GET or POST.</p>"))
