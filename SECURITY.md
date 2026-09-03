# Security

## Reporting a vulnerability

If you discover a potential security issue in this project, please notify AWS/Amazon Security through the [vulnerability reporting page](http://aws.amazon.com/security/vulnerability-reporting/). Do **not** create a public GitHub issue for security reports.

## Scope and intent of this repository

This is a reference implementation. It is designed to be readable and to demonstrate a secure architectural pattern, and it is **not a drop-in production configuration**. Several settings are intentionally left in a reference-friendly state so the code deploys cleanly into a sample account. Before running this in production, review and apply the hardening steps below. Each item is a deliberate, disclosed trade-off, not an oversight.

## Production-hardening checklist (accepted security debt)

### 1. Approver review endpoint is publicly reachable (app-layer token auth)

- **What it is.** The approver Lambda sits behind an API Gateway HTTP API so the review link is clickable from a plain email client for the full approval window. The Lambda's resource policy names only `apigateway.amazonaws.com` scoped to this one API (no `Principal: "*"` anywhere), and the stage is throttled and access-logged. Authentication is enforced in the application layer by a KMS-signed, single-use, time-limited (14-day) approval token validated on every request, backed by a DynamoDB conditional write that makes each approval idempotent and replay-proof.
- **Residual risk if unaddressed.** The HTTPS endpoint itself is reachable from the internet; security rests on the token, the throttle, and the single-use gate. The Lambda executes for requests that reach it through the API.
- **Production recommendation.** For approvers with SSO identities, front the review UI with an authenticated web application (or an internal, VPC-only load balancer) that signs `AWS_IAM` requests server-side, and optionally attach AWS WAF to the API stage. All options preserve the KMS-token and DynamoDB controls while adding an authentication or network boundary at the edge.

### 2. KMS key policy grants `kms:*` to the account root

- **What it is.** The frozen-store bucket key and the control-plane token key use a key policy that grants `kms:*` to the account root principal, the AWS default that keeps the key manageable.
- **Residual risk if unaddressed.** Any principal in the production account with the right IAM permissions can administer the key.
- **Production recommendation.** Scope the key-administration statement to the specific deploy role rather than the account root, for example `arn:aws:iam::<ACCOUNT_ID>:role/FrozenRepoDeploymentRole`, and grant only the usage actions each consumer needs.

### 3. S3 server access logging is off (frozen-store and patch-logs buckets)

- **What it is.** Server access logging is not enabled on the frozen-store and patch-logs buckets in the reference configuration.
- **Residual risk if unaddressed.** There is no server-side access trail to reconstruct object-level access during an incident.
- **Production recommendation.** Enable S3 server access logging (or CloudTrail S3 data events) on both buckets and send the logs to a dedicated, restricted log bucket.

### 4. Patch-log bucket versioning is disabled (intentional)

- **What it is.** The patch-log bucket is created without versioning.
- **Residual risk if unaddressed.** Deleted or overwritten patch-log objects are unrecoverable.
- **Production recommendation.** Enable versioning if patch logs are retained as compliance evidence (for example under SOC 2 or FDA 21 CFR Part 11), and pair it with a lifecycle and object-lock policy appropriate to your retention requirements.

### 5. Mirror load balancer access logs are off unless configured

- **What it is.** The mirror's load balancer only emits access logs when `access_logs_bucket` is set, and it is unset by default.
- **Residual risk if unaddressed.** There is no request-level record of who fetched what from the mirror.
- **Production recommendation.** Always supply `access_logs_bucket` in production so the mirror produces a request-level access log.

### 6. Sync task security group allows HTTPS egress to any destination

- **What it is.** The sync engine is the single component whose job is fetching from the public internet (upstream OS mirrors) and it also writes to S3 in another region. The upstream mirrors are CDN-backed with rotating IPs and publish no stable CIDR range, and security groups match the final destination IP, so its security group carries one deliberate `443 -> 0.0.0.0/0` egress rule. Every other security group in this repository is fully scoped: the mirror task egresses only to the S3 gateway-endpoint prefix list and an interface-endpoint security group, and the internal ALB rejects open ingress CIDRs by variable validation.
- **Residual risk if unaddressed.** A compromised sync task could exfiltrate over HTTPS to arbitrary destinations during its run window.
- **Production recommendation.** Route the sync task's egress through AWS Network Firewall (or an egress proxy) with an FQDN allowlist restricted to your upstream mirror domains and the S3 endpoint, and scope this security-group rule to the firewall endpoint instead of `0.0.0.0/0`.

## Dependencies

Runtime third-party dependencies are pinned to exact versions (see the `requirements.txt` files under `lambdas/` and the pinned versions in `containers/*/Dockerfile`). Re-run a dependency vulnerability scan (for example `pip-audit` on the Lambda requirements and an image scan such as `grype` on the built containers) as part of your own release process before deploying.
