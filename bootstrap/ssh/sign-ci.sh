#!/usr/bin/env bash
# Non-interactive counterpart to sign.sh — signs a fresh certificate over
# ansible-console's existing keypair using an AppRole credential instead of a
# human-typed Vault token, so CI can authenticate without a person in the
# loop. Run before `make deploy-nodes`/`deploy-cluster` in CI; a human never
# runs this directly.
#
#   bootstrap/ssh/sign-ci.sh
#
# role_id/secret_id are read from files, not env vars: they live only on
# 1972-console-1 (cluster/vault/README.md's AppRole step), the same way
# ansible-console's own key never enters GitHub. Output goes to
# ${KEY}-cert.pub, group:docker mode:0640 — matching ansible-console's own
# permissions, since CI reads both from inside the containerized runner, a
# sibling container over the shared docker socket that only bridges identity
# through docker-group membership. See that key's generation task in
# 20-cicd-host.yml for the full reasoning.
set -euo pipefail

ROLE_ID_FILE="${VAULT_CI_ROLE_ID_FILE:-$HOME/.ssh/vault-ci-role-id}"
SECRET_ID_FILE="${VAULT_CI_SECRET_ID_FILE:-$HOME/.ssh/vault-ci-secret-id}"
KEY="${VAULT_SSH_KEY:-$HOME/.ssh/ansible-console}"
ROLE="${VAULT_SSH_ROLE:-admin}"
USER_NAME="${VAULT_SSH_USER:-mchellmer}"

if ! command -v vault >/dev/null 2>&1; then
  echo "error: vault CLI not found in this image" >&2
  exit 1
fi

if [[ -z "${VAULT_ADDR:-}" ]]; then
  echo "error: VAULT_ADDR is unset (e.g. https://vault.\${LAB_DOMAIN})" >&2
  exit 1
fi

for f in "$ROLE_ID_FILE" "$SECRET_ID_FILE" "${KEY}.pub"; do
  if [[ ! -f "$f" ]]; then
    echo "error: $f not found. See cluster/vault/README.md's AppRole step." >&2
    exit 1
  fi
done

VAULT_TOKEN=$(vault write -field=token auth/approle/login \
  role_id="$(cat "$ROLE_ID_FILE")" \
  secret_id="$(cat "$SECRET_ID_FILE")")
export VAULT_TOKEN

CERT="${KEY}-cert.pub"
vault write -field=signed_key "ssh-client-signer/sign/${ROLE}" \
  public_key="@${KEY}.pub" \
  valid_principals="${USER_NAME}" > "$CERT"
chmod 640 "$CERT"
chgrp docker "$CERT"

echo "certificate written to ${CERT} (expires in ~5m)"
