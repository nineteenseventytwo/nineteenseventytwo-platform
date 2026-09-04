#!/usr/bin/env bash
# Request a short-lived SSH certificate from Vault and connect with it.
#
#   bootstrap/ssh/sign.sh <host> [user]
#
# HOST is optional: with none, signs the cert and exits without connecting
# anywhere — `make sign-ws` uses exactly this to put a fresh
# ansible-workstation-cert.pub in place before a workstation-run
# `make deploy-nodes`/`deploy-cluster`, which need a *file* to mount into
# their container, not an interactive session. Same signing path either way,
# so there's one place this logic lives rather than two scripts to keep in
# sync.
#
# Phase D only — this fails cleanly until Vault's ssh-client-signer engine
# exists. The certificate TTL is 5 minutes by design: it expires before you have
# finished making tea, which is the entire point.
set -euo pipefail

HOST="${1:-}"
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
# Sign into a temp file, not $CERT directly: `>` truncates its target before
# vault write ever runs, so a failed sign — bad token, CIDR rejection,
# whatever — left a real, 0-byte $CERT behind despite `set -e` catching the
# failure immediately after. That file is exactly what the Makefile's
# SSH_CERT wildcard mount looks for, and sign-only mode (no HOST) exists
# specifically so this file outlives the script for something else to use
# later — an empty one sitting there is a landmine, not a mistake that fails
# loudly next time.
TMP_CERT="$(mktemp "${CERT}.XXXXXX")"
trap 'rm -f "$TMP_CERT"' EXIT
vault write -field=signed_key "ssh-client-signer/sign/${ROLE}" \
  public_key="@${KEY}.pub" \
  valid_principals="${USER_NAME}" > "$TMP_CERT"
chmod 600 "$TMP_CERT"
mv "$TMP_CERT" "$CERT"
trap - EXIT

echo "certificate written to ${CERT} (expires in ~5m)"

if [[ -z "$HOST" ]]; then
  exit 0
fi

# -i "$KEY" alone is enough: OpenSSH auto-discovers the sibling
# <key>-cert.pub file by naming convention and offers key+cert together as
# one identity. Passing -i "$CERT" *as well* used to double-specify the same
# identity - each -i registers its own candidate, so the cert got offered
# twice (once via its own -i, once via auto-discovery through the key's -i)
# on top of whatever an ssh-agent or ~/.ssh/config also contributes for the
# same key. Confirmed live: that reliably exceeds this cluster's own
# MaxAuthTries 3 (ansible/roles/hardening/templates/10-hardening.conf.j2)
# before the valid identity ever gets its turn - "Too many authentication
# failures" with a freshly-signed, correctly-typed-passphrase certificate,
# on every node, not a fluke or a stale cert.
exec ssh -i "$KEY" -o IdentitiesOnly=yes "${USER_NAME}@${HOST}"
