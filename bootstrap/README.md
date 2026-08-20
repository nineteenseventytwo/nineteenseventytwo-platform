# bootstrap/

Everything here runs **before** Ansible can reach a node, by hand, exactly once
per host. Nothing in this directory is idempotent and nothing in it is run by CI.

## cloud-init/

Flash vanilla **Ubuntu 24.04 LTS arm64** with the Raspberry Pi Imager and skip
its "advanced options" panel entirely — that panel just writes cloud-init files
to the boot partition, and clicking through it four times is how hosts drift.

Instead:

```bash
make bootstrap-render HOST=1972-master-1
# -> build/1972-master-1/user-data
# -> build/1972-master-1/network-config
```

Copy both files onto the FAT boot partition (`/boot/firmware/` once booted,
`system-boot` when mounted on your workstation), then boot the Pi.

The templates are rendered from `ansible/inventory/lab/hosts.yml`, so the
inventory is the single source of truth for hostnames, addresses and roles.

### What the rendered `user-data` does

- Creates the single admin user with both workstation public keys
  (`mark-workstation`, `ansible-workstation`). No others.
- `ssh_pwauth: false` and `lock_passwd: true` — password auth is off from first
  boot, not "off once Ansible runs".
- Writes `/etc/ssh/sshd_config.d/10-hardening.conf` so the very first SSH
  connection is already hardened.
- On the three **cluster** nodes only, appends
  `cgroup_enable=memory cgroup_memory=1` to `/boot/firmware/cmdline.txt` and
  reboots once. kubelet will not start without it. `1972-console-1` skips this.
- Installs a deliberately minimal package set. Ansible does the rest.

### Addressing

Per [ADR-0009](../docs/decisions/ADR-0009-dhcp-authority.md), **Kea reservations
on OPNsense are authoritative** and cloud-init uses DHCP. A reimaged Pi comes up
on the right address with no local edits, and addressing lives in one place.

`network-config` therefore renders a DHCP stanza by default. Set
`cloudinit_use_static: true` in group_vars to render a static stanza instead —
useful only if you are bringing up a node before OPNsense knows about it.

## ssh/

Phase A ships **keys**. Phase D swaps in a Vault SSH **certificate authority**
and Ansible adds `TrustedUserCAKeys` to `sshd_config`; the helpers here cover
both. See [docs/04-secrets.md](../docs/04-secrets.md) §Tier 3.

| Key | Passphrase | Lives where | Used for |
|---|---|---|---|
| `mark-workstation` (ed25519) | **yes** | Mac + Windows workstation; private key never leaves them | humans typing `ssh`, break-glass. Never used by automation |
| `ansible-workstation` (ed25519) | no | Same workstations, alongside the above | containerised Ansible launched from a workstation (Phase A/B, before CI exists) |
| `ansible-console` (ed25519) | no | Generated *on* `1972-console-1`, never committed | containerised Ansible launched from CI, which runs on that host |
| GitHub App private key | — | SOPS-encrypted + org Actions secret | runner registration |

No private key is ever transported: each is generated where it is used and
stays there. That is what lets the automation keys go without a passphrase
safely — and they have to, because the thing using them is a container with no
TTY to prompt at. The human key keeps its passphrase precisely because it is
the one that lives on portable hardware.

Put the **public** half of both workstation keys in `bootstrap/ssh/` before
rendering cloud-init; `render.sh` writes all of them into every node's
`authorized_keys` and refuses to render if one is missing. `.gitignore` allows
`bootstrap/ssh/*.pub` and blocks everything else in the directory that looks
like a private key.
