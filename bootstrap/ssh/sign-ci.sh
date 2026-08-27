#!/usr/bin/env bash
# Non-interactive counterpart to sign.sh — signs a fresh certificate over
# ansible-console's keypair using an AppRole credential instead of a
# human-typed Vault token, so CI can authenticate without a person in the
# loop. Run before `make deploy-nodes`/`deploy-cluster` in CI; a human never
# runs this directly.
#
#   bootstrap/ssh/sign-ci.sh
#
# Every path here is a *container* path, because this runs inside the
# containerized self-hosted runner — not on console's own filesystem. That
# distinction is the whole reason this script looks the way it does:
#
#   /vault-ci  is a read-only bind mount of the host's
#              {{ runner_host_vault_ci_dir }} (compose.yml.j2). It carries the
#              AppRole credentials and ansible-console's *public* key. The
#              private key is deliberately absent — signing never needs it,
#              and the runner container has no business holding it.
#
#   $RUNNER_TEMP is host-path-identical: the runner's _work directory is bind
#              mounted at the same absolute path on both sides, so anything
#              written here is visible to the host at the same path and can be
#              mounted into the sibling ansible-runner container the Makefile
#              spawns over the shared docker socket. The workflow passes this
#              path on as SSH_CERT. Same mechanism deploy-nodes.yml already
#              uses to hand the age key to that sibling.
#
# Writing the cert next to the private key instead would put it at
# /home/runner/.ssh inside this container — invisible to the host, and so
# invisible to the sibling that actually needs it.
set -euo pipefail

VAULT_CI_DIR="${VAULT_CI_DIR:-/vault-ci}"
ROLE_ID_FILE="${VAULT_CI_ROLE_ID_FILE:-$VAULT_CI_DIR/role-id}"
SECRET_ID_FILE="${VAULT_CI_SECRET_ID_FILE:-$VAULT_CI_DIR/secret-id}"
PUBKEY="${VAULT_SSH_PUBKEY:-$VAULT_CI_DIR/ansible-console.pub}"
ROLE="${VAULT_SSH_ROLE:-admin}"
USER_NAME="${VAULT_SSH_USER:-mchellmer}"
CERT="${SSH_CERT_OUT:-${RUNNER_TEMP:-/tmp}/ansible-console-cert.pub}"

if ! command -v vault >/dev/null 2>&1; then
  echo "error: vault CLI not found in this image" >&2
  exit 1
fi

if [[ -z "${VAULT_ADDR:-}" ]]; then
  echo "error: VAULT_ADDR is unset (e.g. https://vault.\${LAB_DOMAIN})" >&2
  exit 1
fi

for f in "$ROLE_ID_FILE" "$SECRET_ID_FILE" "$PUBKEY"; do
  if [[ ! -f "$f" ]]; then
    echo "error: $f not found." >&2
    echo "       role-id/secret-id are placed by hand once — see" >&2
    echo "       cluster/vault/README.md's AppRole step." >&2
    echo "       ansible-console.pub is placed by 20-cicd-host.yml" >&2
    echo "       (make deploy-cicd from a workstation)." >&2
    exit 1
  fi
done

VAULT_TOKEN=$(vault write -field=token auth/approle/login \
  role_id="$(cat "$ROLE_ID_FILE")" \
  secret_id="$(cat "$SECRET_ID_FILE")")
export VAULT_TOKEN

vault write -field=signed_key "ssh-client-signer/sign/${ROLE}" \
  public_key="@${PUBKEY}" \
  valid_principals="${USER_NAME}" > "$CERT"
chmod 644 "$CERT"

echo "certificate written to ${CERT} (expires in ~5m)"
