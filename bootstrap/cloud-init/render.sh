#!/usr/bin/env bash
# Render cloud-init user-data + network-config for one host.
#
#   bootstrap/cloud-init/render.sh <hostname> [output-dir]
#
# The inventory (ansible/inventory/lab/hosts.yml) is the single source of truth
# for hostnames, addresses and roles, so this shells out to ansible rather than
# re-implementing the lookup. Uses the ansible-runner image unless
# RUNNER_LOCAL=1 or ansible-playbook is already on PATH.
set -euo pipefail

HOST="${1:?usage: render.sh <hostname> [output-dir]}"
OUT="${2:-build/${HOST}}"

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_ROOT"

KEY_NAME="${ADMIN_SSH_KEY_NAME:-mark-workstation}"
if [[ ! -f "bootstrap/ssh/${KEY_NAME}.pub" ]]; then
  cat >&2 <<MSG
error: bootstrap/ssh/${KEY_NAME}.pub not found.

The rendered user-data is the only thing that grants access to a freshly imaged
node, so refusing to render without a key is deliberate — a host booted with an
empty authorized_keys needs a monitor and a keyboard to recover.

  ssh-keygen -t ed25519 -C "${KEY_NAME}" -f ~/.ssh/${KEY_NAME}
  cp ~/.ssh/${KEY_NAME}.pub bootstrap/ssh/

(On Windows/PuTTY: generate in PuTTYgen and export the OpenSSH public key.)
MSG
  exit 1
fi

ARGS=(
  bootstrap/cloud-init/render.yml
  -i ansible/inventory/lab
  -e "target_host=${HOST}"
  -e "output_dir=${OUT}"
  -e "admin_ssh_key_name=${KEY_NAME}"
)

if [[ "${RUNNER_LOCAL:-0}" == "1" ]] || command -v ansible-playbook >/dev/null 2>&1; then
  ANSIBLE_CONFIG=ansible/ansible.cfg ansible-playbook "${ARGS[@]}"
else
  ORG="${ORG:-nineteenseventytwo}"
  IMAGE="${ANSIBLE_RUNNER:-ghcr.io/${ORG}/ansible-runner:$(cat images/ansible-runner/version.txt)}"
  docker run --rm -i \
    -v "$PWD:/work" -w /work \
    -e ANSIBLE_CONFIG=/work/ansible/ansible.cfg \
    "$IMAGE" ansible-playbook "${ARGS[@]}"
fi

echo
echo "Next: copy ${OUT}/user-data and ${OUT}/network-config onto the boot"
echo "partition of ${HOST}'s SSD, then boot it."
