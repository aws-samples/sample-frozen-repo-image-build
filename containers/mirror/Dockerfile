# Build aws-sigv4-proxy v1.12 or later from an immutable source commit.
# v1.12 includes the S3 special-character URL fix from upstream PR #273.
FROM public.ecr.aws/docker/library/golang:1.26-alpine AS sigv4-build
RUN apk add --no-cache git ca-certificates
RUN git clone https://github.com/awslabs/aws-sigv4-proxy.git /src
WORKDIR /src
# Full v1.12 release commit; override only with another reviewed 40-character SHA.
ARG SIGV4_PROXY_COMMIT=0281c3271e65ca05fbb143a2f8ffbde7eda41179
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
