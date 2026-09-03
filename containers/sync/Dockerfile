FROM public.ecr.aws/amazonlinux/amazonlinux:2023

ARG BOTO3_VERSION=1.42.97

LABEL org.opencontainers.image.description="Frozen repo sync task: reposync, GPG verify, S3 upload" \
      org.opencontainers.image.title="frozen-repo-sync"

RUN dnf install -y --allowerasing \
      rpm \
      gnupg2 \
      createrepo_c \
      python3 \
      python3.14 \
      python3.14-pip \
      curl \
      jq \
      findutils \
      unzip \
      dnf-plugins-core \
      yum-utils \
      shadow-utils \
    && ln -sf /usr/bin/python3.14 /usr/local/bin/python3 \
    && pip3.14 install --no-cache-dir boto3==${BOTO3_VERSION} \
    && dnf clean all \
    && rm -rf /var/cache/dnf
# dnf needs the distro Python (3.9) at /usr/bin/python3 (AL2023 forbids repointing it),
# so leave it; the /usr/local/bin/python3 symlink wins on PATH so scripts use 3.14 + boto3.

# AWS CLI v2, official binary installer
RUN curl -fsSL -o /tmp/awscli.zip https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip \
    && unzip -q /tmp/awscli.zip -d /tmp \
    && /tmp/aws/install \
    && rm -rf /tmp/aws /tmp/awscli.zip

# GPG keys for the os_matrix families (rhel810 = AlmaLinux 8 + EPEL 8, rhel79 = CentOS 7 + EPEL 7).
# Every family you mirror MUST have its signing key imported here or GPG verification fails.
RUN mkdir -p /etc/pki/rpm-gpg-frozen \
    && curl -fsSL -o /etc/pki/rpm-gpg-frozen/RPM-GPG-KEY-AlmaLinux \
         https://repo.almalinux.org/almalinux/RPM-GPG-KEY-AlmaLinux \
    && curl -fsSL -o /etc/pki/rpm-gpg-frozen/RPM-GPG-KEY-EPEL-8 \
         https://dl.fedoraproject.org/pub/epel/RPM-GPG-KEY-EPEL-8 \
    && curl -fsSL -o /etc/pki/rpm-gpg-frozen/RPM-GPG-KEY-CentOS-7 \
         https://vault.centos.org/RPM-GPG-KEY-CentOS-7 \
    && curl -fsSL -o /etc/pki/rpm-gpg-frozen/RPM-GPG-KEY-EPEL-7 \
         https://dl.fedoraproject.org/pub/epel/RPM-GPG-KEY-EPEL-7 \
    && rpm --import /etc/pki/rpm-gpg-frozen/RPM-GPG-KEY-*

RUN useradd -r -u 1000 -m -d /home/reposync -s /bin/bash reposync \
    && mkdir -p /data/sync /app \
    && chown -R reposync:reposync /data/sync /app /etc/pki/rpm-gpg-frozen

COPY --chown=reposync:reposync sync.sh /app/sync.sh
COPY --chown=reposync:reposync validate_packages.sh /app/validate_packages.sh
COPY --chown=reposync:reposync pkg-lists/ /app/pkg-lists/
RUN chmod +x /app/sync.sh /app/validate_packages.sh

# PKG_LISTS drives validate_packages.sh: space-separated "list_file:os_prefix:repo1,repo2,..."
# entries (informational, never blocks a sync). Override at runtime for your OS matrix.
ENV PKG_LISTS="/app/pkg-lists/custom_packages810.txt:rhel810:baseos,appstream,epel /app/pkg-lists/custom_packages79.txt:rhel79:base,updates,epel"

USER reposync
WORKDIR /app
ENTRYPOINT ["/app/sync.sh"]
