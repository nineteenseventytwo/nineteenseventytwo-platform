# bootstrap/ssh/

Only **public** keys belong in this directory. `.gitignore` permits `*.pub` and
blocks `*.key` / `*.pem`; if you find yourself fighting it, you are about to
commit a private key.

| File | What it is |
|---|---|
| `mark-workstation.pub` | Your workstation public key. Rendered into every node's cloud-init. **You must add this before the first `make bootstrap-render`.** |
| `ca.pub` | Vault SSH CA public key, added in Phase D. Ansible's `hardening` role drops it at `/etc/ssh/ca.pub` and sets `TrustedUserCAKeys`. |
| `break-glass.pub` | The one key that survives the Phase D cutover. Public half only — the private key is generated once, added to `1972-console-1`'s `authorized_keys` here, and then kept **offline**, never on this machine or any node. Absent by design until you're actually ready for cutover; `hardening_ssh_retire_legacy_keys` (`ansible/roles/hardening/defaults/main.yml`) is inert without it. |

## Phase A — keys

```bash
ssh-keygen -t ed25519 -C "mark-workstation" -f ~/.ssh/mark-workstation
cp ~/.ssh/mark-workstation.pub bootstrap/ssh/
```

The `ansible-console` key is generated **on** `1972-console-1` by the
`20-cicd-host.yml` playbook and never leaves it. That is why there is no
template for it here.

## Phase D — certificates

What Phase A ships are SSH *keys*. A real SSH CA signs short-lived
*certificates*, so nodes trust the CA instead of a list of keys: no
`authorized_keys` drift, revocation that actually works, and an audit trail of
who asked for access to what.

```bash
# once, after Vault is up (see docs/04-secrets.md)
vault secrets enable -path=ssh-client-signer ssh
vault write ssh-client-signer/config/ca generate_signing_key=true
vault read -field=public_key ssh-client-signer/config/ca > bootstrap/ssh/ca.pub

# then per session, from your workstation
./bootstrap/ssh/sign.sh 192.168.20.202
```

The cutover this enables is done (2026-08-28,
[docs/plan/05-provisioning-completion-plan.md](../../docs/plan/05-provisioning-completion-plan.md)
WP-3.1): a certificate is the only way onto `1972-master-1`, `1972-worker-1`
and `1972-worker-2` now, and onto `1972-console-1` alongside break-glass.
`make ssh-ws HOST=<ip>` wraps the two exports `sign.sh` needs (`VAULT_ADDR`,
and a `VAULT_TOKEN` prompt if your shell doesn't already have one) so you
don't retype them every session — same script underneath, nothing new to
learn if you'd rather call it directly.

CI has its own, non-interactive equivalent
(`bootstrap/ssh/sign-ci.sh`, AppRole instead of a typed token) — see
[docs/02-cicd.md](../../docs/02-cicd.md). Running `make deploy-nodes` or
similar Ansible targets *from a workstation* rather than as a human `ssh`
session is a third case, closed the same shape rather than with a third
script: `sign.sh`'s `HOST` argument is optional, and `make sign-ws` uses
that to sign `ansible-workstation-cert.pub` and exit without connecting
anywhere — the Makefile's own mount for it already exists, so
`make deploy-nodes` picks it up with no further changes once signed.

Keep one break-glass static key on `1972-console-1`, offline, for when Vault is
the thing that is down. It is the only `authorized_keys` entry that survives the
CA cutover.
