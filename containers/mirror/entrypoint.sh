#!/bin/bash
set -euo pipefail

# S3_BUCKET / S3_REGION are injected by the task definition (mirror module).
# No functional default for the bucket: it must be provided, so the mirror can
# never silently sign for the wrong (or a reserved-name) bucket.
S3_BUCKET="${S3_BUCKET:?S3_BUCKET must be set (frozen store bucket name)}"
S3_REGION="${S3_REGION:-us-west-2}"
S3_HOST="${S3_BUCKET}.s3.${S3_REGION}.amazonaws.com"

# Render the nginx upstream Host from the SAME S3_HOST the signer uses, so the
# proxy signature and the Host header can never diverge (a mismatch => 403).
sed -i "s|__S3_HOST__|${S3_HOST}|g" /etc/nginx/nginx.conf

aws-sigv4-proxy \
  --name s3 \
  --region "${S3_REGION}" \
  --host "${S3_HOST}" \
  --port ":9090" \
  --log-failed-requests \
  &

for i in $(seq 1 10); do
  if curl -sf http://127.0.0.1:9090/ >/dev/null 2>&1; then
    break
  fi
  sleep 1
done

exec nginx -g 'daemon off;'
