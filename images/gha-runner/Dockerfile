# gha-runner — thin, tracks upstream closely, changes rarely.
#
# Deliberately does NOT contain Ansible. Baking it in means a collection bump
# forces a runner rebuild and a runner CVE forces an Ansible revalidation; the
# workflow instead does `docker run ansible-runner ...` from inside this one.
FROM ghcr.io/actions/actions-runner:2.336.0

ARG DOCKER_CLI_VERSION=29.7.2
ARG TARGETARCH=aarch64

LABEL org.opencontainers.image.source="https://github.com/nineteenseventytwo/nineteenseventytwo-platform" \
      org.opencontainers.image.description="GitHub Actions runner + docker CLI, org-scoped and ephemeral" \
      org.opencontainers.image.licenses="MIT"

USER root

RUN apt-get update \
 && apt-get install --no-install-recommends -y \
      ca-certificates curl git jq openssl \
 && rm -rf /var/lib/apt/lists/*

# The docker *CLI* only. The daemon is the host's, reached through the mounted
# socket — which is approximately root on the host, and the reason this stack
# moves to ARC dind once the cluster exists (ADR-0006).
RUN curl -fsSL "https://download.docker.com/linux/static/stable/${TARGETARCH}/docker-${DOCKER_CLI_VERSION}.tgz" \
      | tar -xz -C /tmp \
 && mv /tmp/docker/docker /usr/local/bin/docker \
 && rm -rf /tmp/docker \
 && docker --version

# Ephemeral by default: one job, then the container exits and is replaced. All
# repo state comes from actions/checkout in the job itself.
ENV RUNNER_ALLOW_RUNASROOT=0 \
    DISABLE_AUTO_UPDATE=true

# App-auth registration (docs/02-cicd.md): mints its own token at start
# instead of taking one as an argument. See entrypoint.sh for the flow.
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

USER runner
WORKDIR /home/runner
ENTRYPOINT ["/entrypoint.sh"]
