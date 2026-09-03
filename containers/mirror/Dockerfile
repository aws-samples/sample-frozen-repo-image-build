# Build aws-sigv4-proxy from source: later commits fix URL-encoding of '+' in
# package names (libstdc++, gcc-c++), which otherwise fail SigV4 with 403.
FROM public.ecr.aws/docker/library/golang:1.26-alpine AS sigv4-build
RUN apk add --no-cache git ca-certificates
RUN git clone https://github.com/awslabs/aws-sigv4-proxy.git /src
WORKDIR /src
# Pinned to the full 40-char SHA carrying the '+'-in-package-name URL-encoding fix (never a mutable branch).
# Override: --build-arg SIGV4_PROXY_COMMIT=<full-40-char-sha>
ARG SIGV4_PROXY_COMMIT=4165dc78f51d8faae974f6d3091d2e1c14bdb4b1
RUN git checkout "${SIGV4_PROXY_COMMIT}" \
    && go env -w GOPROXY=direct \
    && CGO_ENABLED=0 GOOS=linux go build -o /aws-sigv4-proxy ./cmd/aws-sigv4-proxy

FROM public.ecr.aws/nginx/nginx:1.31-alpine

LABEL org.opencontainers.image.description="Frozen repo Nginx mirror with S3 SigV4 proxy" \
      org.opencontainers.image.title="frozen-repo-mirror"

RUN apk add --no-cache curl bash

COPY --from=sigv4-build /aws-sigv4-proxy /usr/local/bin/aws-sigv4-proxy

COPY nginx.conf /etc/nginx/nginx.conf
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

RUN mkdir -p /tmp/nginx /var/cache/nginx /var/run \
    && chown -R nginx:nginx /tmp/nginx /var/cache/nginx /var/run /etc/nginx

EXPOSE 8080
USER nginx
ENTRYPOINT ["/entrypoint.sh"]
