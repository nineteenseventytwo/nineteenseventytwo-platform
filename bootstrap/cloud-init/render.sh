#!/usr/bin/env bash
# Render cloud-init user-data + network-config for one host.
#
#   bootstrap/cloud-init/render.sh <hostname> [output-dir]
#
# The inventory (ansible/inventory/lab/hosts.yml) is the single source of truth
# for hostnames, addresses and roles, so this shells out to ansible rather than
# re-implementing the lookup. Uses the ansible-runner image via podman unless
# RUNNER_LOCAL=1 or ansible-playbook is already on PATH. Always podman, not
# ENGINE-conditional like the Makefile's CONTAINER_RUN: this step never
# touches a live node — pure local templating, run by hand before a node
# exists to image an SD card — so CI never calls it and the workstation's
# podman-only rule always applies.
set -euo pipefail

HOST="${1:?usage: render.sh <hostname> [output-dir]}"
OUT="${2:-build/${HOST}}"

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_ROOT"

# Absolutize against REPO_ROOT (the host filesystem) regardless of what was
# passed in. render.yml's `template`/`file` tasks run under `connection:
# local`, and that connection plugin chdirs the process to the *playbook's
# own directory* (bootstrap/cloud-init/) before resolving a relative dest —
# confirmed live via a probe task: `pwd` inside the play reported
# /work/bootstrap/cloud-init, not /work, with -w /work set. A relative OUT of
# "build/<HOST>" landed at bootstrap/cloud-init/build/<HOST>, silently, while
# every doc (00-bootstrap.md, README.md) says build/<HOST>. This is true
# whether ansible-playbook runs bare on the host or inside the container —
# the chdir happens either way.
case "$OUT" in
  /*) ;;
  *) OUT="$REPO_ROOT/$OUT" ;;
esac

# Both keys go into every node's authorized_keys: mark-workstation for humans
# (passphrase-protected), ansible-workstation for the containerised Ansible you
# run from here during Phase A/B (no passphrase — a container has no TTY to
# prompt at). See bootstrap/ssh/README.md for the full three-key model.
KEY_NAMES="${ADMIN_SSH_KEY_NAMES:-mark-workstation,ansible-workstation}"

for KEY_NAME in ${KEY_NAMES//,/ }; do
  [[ -f "bootstrap/ssh/${KEY_NAME}.pub" ]] && continue

  # Automation keys must have no passphrase; human keys must have one.
  if [[ "$KEY_NAME" == ansible-* ]]; then
    KEYGEN="ssh-keygen -t ed25519 -C \"${KEY_NAME}\" -f ~/.ssh/${KEY_NAME} -N \"\""
  else
    KEYGEN="ssh-keygen -t ed25519 -C \"${KEY_NAME}\" -f ~/.ssh/${KEY_NAME}"
  fi

  cat >&2 <<MSG
error: bootstrap/ssh/${KEY_NAME}.pub not found.

The rendered user-data is the only thing that grants access to a freshly imaged
node, so refusing to render without a key is deliberate — a host booted with an
empty authorized_keys needs a monitor and a keyboard to recover.

  ${KEYGEN}
  cp ~/.ssh/${KEY_NAME}.pub bootstrap/ssh/

(On Windows/PuTTY: generate in PuTTYgen and export the OpenSSH public key.)
MSG
  exit 1
done

ARGS=(
  bootstrap/cloud-init/render.yml
  -i ansible/inventory/lab
  -e "target_host=${HOST}"
  -e "admin_ssh_key_names=${KEY_NAMES}"
)

if [[ "${RUNNER_LOCAL:-0}" == "1" ]] || command -v ansible-playbook >/dev/null 2>&1; then
  # Runs directly on the host, so OUT (already absolute, host-side) needs no
  # translation.
  ANSIBLE_CONFIG=ansible/ansible.cfg ansible-playbook "${ARGS[@]}" -e "output_dir=${OUT}"
else
  ORG="${ORG:-nineteenseventytwo}"
  IMAGE="${ANSIBLE_RUNNER:-ghcr.io/${ORG}/ansible-runner:$(cat images/ansible-runner/version.txt)}"
  # The age key is needed even though this play never leaves localhost: loading
  # the lab inventory pulls in group_vars/all/secrets.sops.yml, and the
  # community.sops vars plugin decrypts it at inventory-load time.
  #
  # Mounted at /home/ansible, not /root: the image's default (and only, since
  # nothing here overrides --user the way the Makefile's CONTAINER_RUN does)
  # user is `ansible`, HOME=/home/ansible per the Dockerfile. Mounting to
  # /root put the key somewhere this process can't even read, let alone find -
  # sops looks under $HOME, and $HOME was never /root here. --user matches
  # CONTAINER_RUN's own pattern so the rendered output isn't left owned by
  # the container's internal uid instead of yours.
  SOPS_AGE_DIR="${SOPS_AGE_DIR:-$HOME/.config/sops/age}"
  # OUT is a host-absolute path under REPO_ROOT, which the -v mount below
  # puts at /work — rewrite it to the equivalent /work/... path so the
  # container-side chdir (see above) resolves to the right place, and the
  # file actually lands under REPO_ROOT/build/<HOST> on the host as promised.
  OUT_CONTAINER="/work/${OUT#"$REPO_ROOT"/}"
  podman run --rm -i --user "$(id -u):$(id -g)" \
    -v "$PWD:/work" -w /work \
    -v "$SOPS_AGE_DIR:/home/ansible/.config/sops/age:ro" \
    -e ANSIBLE_CONFIG=/work/ansible/ansible.cfg \
    "$IMAGE" ansible-playbook "${ARGS[@]}" -e "output_dir=${OUT_CONTAINER}"
fi

echo
echo "Next: copy ${OUT}/user-data and ${OUT}/network-config onto the boot"
echo "partition of ${HOST}'s SSD, then boot it."
