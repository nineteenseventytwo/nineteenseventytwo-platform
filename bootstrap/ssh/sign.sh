#!/usr/bin/env bash
# Request a short-lived SSH certificate from Vault and connect with it.
#
#   bootstrap/ssh/sign.sh <host> [user]
#
# Phase D only — this fails cleanly until Vault's ssh-client-signer engine
# exists. The certificate TTL is 5 minutes by design: it expires before you have
# finished making tea, which is the entire point.
set -euo pipefail

HOST="${1:?usage: sign.sh <host> [user]}"
USER_NAME="${2:-${VAULT_SSH_USER:-mchellmer}}"
ROLE="${VAULT_SSH_ROLE:-admin}"
KEY="${VAULT_SSH_KEY:-$HOME/.ssh/mark-workstation}"

if ! command -v vault >/dev/null 2>&1; then
  echo "error: vault CLI not found. Phase D prerequisite; see docs/04-secrets.md" >&2
  exit 1
fi

if [[ -z "${VAULT_ADDR:-}" ]]; then
  echo "error: VAULT_ADDR is unset (e.g. https://vault.\${LAB_DOMAIN})" >&2
  exit 1
fi

if [[ ! -f "${KEY}.pub" ]]; then
  echo "error: ${KEY}.pub not found; set VAULT_SSH_KEY to your key path" >&2
  exit 1
fi

CERT="${KEY}-cert.pub"
vault write -field=signed_key "ssh-client-signer/sign/${ROLE}" \
  public_key="@${KEY}.pub" \
  valid_principals="${USER_NAME}" > "$CERT"
chmod 600 "$CERT"

echo "certificate written to ${CERT} (expires in ~5m)"
exec ssh -i "$CERT" -i "$KEY" "${USER_NAME}@${HOST}"
