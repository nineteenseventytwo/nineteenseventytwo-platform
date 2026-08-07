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

- Creates the single admin user with your workstation public key. No others.
- `ssh_pwauth: false` and `lock_passwd: true` — password auth is off from first
  boot, not "off once Ansible runs".
- Writes `/etc/ssh/sshd_config.d/10-hardening.conf` so the very first SSH
  connection is already hardened.
- On the three **cluster** nodes only, appends
  `cgroup_enable=memory cgroup_memory=1` to `/boot/firmware/cmdline.txt` and
  reboots once. kubelet will not start without it. `1972-console` skips this.
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

| Key | Lives where | Used for |
|---|---|---|
| `mark-workstation` (ed25519) | Windows workstation agent; private key never leaves it | VLAN 10 → VLAN 20, interactive |
| `ansible-console` (ed25519) | Generated *on* `1972-console`, never committed | console → all nodes, non-interactive |
| GitHub App private key | SOPS-encrypted + org Actions secret | runner registration |

Put the **public** half of `mark-workstation` at `bootstrap/ssh/mark-workstation.pub`
before rendering cloud-init. `.gitignore` allows `bootstrap/ssh/*.pub` and blocks
everything else in the directory that looks like a private key.
