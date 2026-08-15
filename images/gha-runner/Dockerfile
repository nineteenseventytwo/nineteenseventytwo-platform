# gha-runner — thin, tracks upstream closely, changes rarely.
#
# Deliberately does NOT contain Ansible. Baking it in means a collection bump
# forces a runner rebuild and a runner CVE forces an Ansible revalidation; the
# workflow instead does `docker run ansible-runner ...` from inside this one.
ARG RUNNER_VERSION=2.336.0
FROM ghcr.io/actions/actions-runner:${RUNNER_VERSION}

ARG DOCKER_CLI_VERSION=29.7.2

ARG TARGETARCH=arm64

LABEL org.opencontainers.image.source="https://github.com/nineteenseventytwo/nineteenseventytwo-platform" \
      org.opencontainers.image.description="GitHub Actions runner + docker CLI, org-scoped and ephemeral" \
      org.opencontainers.image.licenses="MIT"

USER root

RUN apt-get update \
 && apt-get install --no-install-recommends -y \
      ca-certificates curl git jq make openssl \
 && rm -rf /var/lib/apt/lists/*

RUN case "${TARGETARCH}" in \
      arm64) DOCKER_ARCH=aarch64 ;; \
      amd64) DOCKER_ARCH=x86_64  ;; \
      *) echo "unsupported TARGETARCH: ${TARGETARCH}" >&2; exit 1 ;; \
    esac \
 && curl -fsSL "https://download.docker.com/linux/static/stable/${DOCKER_ARCH}/docker-${DOCKER_CLI_VERSION}.tgz" \
      | tar -xz -C /tmp \
 && mv /tmp/docker/docker /usr/local/bin/docker \
 && rm -rf /tmp/docker \
 && docker --version

ENV RUNNER_ALLOW_RUNASROOT=0 \
    DISABLE_AUTO_UPDATE=true

COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

USER runner
WORKDIR /home/runner
ENTRYPOINT ["/entrypoint.sh"]
