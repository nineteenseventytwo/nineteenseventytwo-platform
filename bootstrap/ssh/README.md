# bootstrap/ssh/

Only **public** keys belong in this directory. `.gitignore` permits `*.pub` and
blocks `*.key` / `*.pem`; if you find yourself fighting it, you are about to
commit a private key.

| File | What it is |
|---|---|
| `mark-workstation.pub` | Your workstation public key. Rendered into every node's cloud-init. **You must add this before the first `make bootstrap-render`.** |
| `ca.pub` | Vault SSH CA public key, added in Phase D. Ansible's `hardening` role drops it at `/etc/ssh/ca.pub` and sets `TrustedUserCAKeys`. |

## Phase A — keys

```bash
ssh-keygen -t ed25519 -C "mark-workstation" -f ~/.ssh/mark-workstation
cp ~/.ssh/mark-workstation.pub bootstrap/ssh/
```

The `ansible-console` key is generated **on** `1972-console` by the
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

Keep one break-glass static key on `1972-console`, offline, for when Vault is
the thing that is down. It is the only `authorized_keys` entry that survives the
CA cutover.
