# ansible-runner — the artefact with real reuse value.
#
# Run from CI, from 1972-console-1, and from a laptop. Versioned and pinned
# independently of anything GitHub does, which is exactly why it is separate
# from the gha-runner image: a collection bump should not force a runner
# rebuild, and a runner CVE should not force an Ansible revalidation.
FROM python:3.14-slim-bookworm

# Renovate/dependabot-friendly pins. Bump deliberately, in a PR, with lint green.
ARG ANSIBLE_CORE_VERSION=2.21.3
ARG KUBECTL_VERSION=v1.36.0
ARG HELM_VERSION=v4.2.3
ARG SOPS_VERSION=v3.13.3
ARG AGE_VERSION=v1.3.1
ARG TARGETARCH=arm64

LABEL org.opencontainers.image.source="https://github.com/nineteenseventytwo/nineteenseventytwo-platform" \
      org.opencontainers.image.description="ansible-core + collections + kubectl + helm + sops + age" \
      org.opencontainers.image.licenses="MIT"

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    ANSIBLE_HOST_KEY_CHECKING=True \
    ANSIBLE_FORCE_COLOR=1

RUN apt-get update \
 && apt-get install --no-install-recommends -y \
      ca-certificates curl git openssh-client rsync \
      sshpass jq shellcheck \
 && rm -rf /var/lib/apt/lists/*

RUN pip install --no-cache-dir \
      "ansible-core==${ANSIBLE_CORE_VERSION}" \
      ansible-lint \
      yamllint \
      kubernetes \
      jmespath \
      netaddr \
      passlib

# kubectl and helm: the deploy-cluster jobs need both, and installing them here
# rather than in the workflow keeps the "CI runs the same thing you do"
# property that the Makefile depends on.
RUN curl -fsSLo /usr/local/bin/kubectl \
      "https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/linux/${TARGETARCH}/kubectl" \
 && chmod +x /usr/local/bin/kubectl \
 && curl -fsSL "https://get.helm.sh/helm-${HELM_VERSION}-linux-${TARGETARCH}.tar.gz" \
      | tar -xz -C /tmp \
 && mv "/tmp/linux-${TARGETARCH}/helm" /usr/local/bin/helm \
 && rm -rf "/tmp/linux-${TARGETARCH}"

# sops + age: Tier 0 secrets. Without these the vars plugin cannot decrypt
# group_vars and every playbook fails on an undefined variable instead of a
# clear "cannot decrypt" error.
RUN curl -fsSLo /usr/local/bin/sops \
      "https://github.com/getsops/sops/releases/download/${SOPS_VERSION}/sops-${SOPS_VERSION}.linux.${TARGETARCH}" \
 && chmod +x /usr/local/bin/sops \
 && curl -fsSL "https://github.com/FiloSottile/age/releases/download/${AGE_VERSION}/age-${AGE_VERSION}-linux-${TARGETARCH}.tar.gz" \
      | tar -xz -C /tmp \
 && mv /tmp/age/age /tmp/age/age-keygen /usr/local/bin/ \
 && rm -rf /tmp/age

COPY requirements.yml /tmp/requirements.yml
RUN ansible-galaxy collection install -r /tmp/requirements.yml -p /usr/share/ansible/collections \
 && rm /tmp/requirements.yml

ENV ANSIBLE_COLLECTIONS_PATH=/usr/share/ansible/collections

# Non-root default. The Makefile's CONTAINER_RUN macros pass
# --user "$(id -u):$(id -g)" at `docker run` time, which overrides this UID
# with whoever actually invoked make — on the workstation that's you, on
# 1972-console-1 (deploy-cluster.yml, deploy-nodes.yml, both self-hosted) it's
# the runner service account. Either way the container ends up owned by
# exactly whoever owns the bind-mounted /work and the credential files under
# $HOME, so there's no UID mismatch to fight on a real Linux bind mount.
#
# HOME stays set and world-writable regardless of which UID lands here via
# --user, since an arbitrary numeric UID has no /etc/passwd entry and would
# otherwise get no $HOME at all — Ansible wants one writable, for
# ~/.ansible/tmp and retry files. This container is ephemeral (--rm) and never
# holds a credential beyond one invocation, so a permissive HOME costs nothing
# a read-only key mount doesn't already cost.
RUN useradd --create-home --shell /usr/sbin/nologin ansible \
 && mkdir -p /home/ansible/.ssh /home/ansible/.config/sops /home/ansible/.kube \
 && chmod -R 0777 /home/ansible
ENV HOME=/home/ansible

# world-writable so an arbitrary UID (via --user, with no matching entry of
# its own) can add itself — see entrypoint.sh for why this matters beyond
# just HOME: ssh's own default-path resolution depends on it.
RUN chmod 0666 /etc/passwd

COPY entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh

USER ansible

WORKDIR /work
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
CMD ["ansible-playbook", "--version"]

# A one-shot CLI invocation (`docker run --rm ansible-runner ansible-playbook
# ...`), not a long-running service — there is no ongoing process for Docker
# to poll. NONE is the honest declaration of that, not an omission.
HEALTHCHECK NONE
