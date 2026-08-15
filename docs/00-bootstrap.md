# 00 — Imaging and first boot

Everything here is manual, once per node/console. It is the only manual step in the
whole repo, and the goal is that it stays that way.

## Prerequisites

- Ubuntu 24.04 LTS **arm64** image (server, not desktop)
- Raspberry Pi Imager, used only to flash the vanilla image
- Your workstation public keys at `bootstrap/ssh/mark-workstation.pub` and
  `bootstrap/ssh/ansible-workstation.pub` — `render.sh` refuses to render
  with either missing. See [bootstrap/README.md](../bootstrap/README.md#ssh)
  for what each is for.
- The Kea reservations already created on OPNsense (see below)

## 1. Reservations first

Addressing authority is OPNsense/Kea ([ADR-0009](decisions/ADR-0009-dhcp-authority.md)),
so a node has an address before it has an OS. Create four reservations matching
the MACs in `ansible/inventory/lab/hosts.yml`:

| Host | MAC (eth0) | Address |
|---|---|---|
| `1972-console-1` | *(pending — new RPi 5 board; run `ip a` after first boot and update `ansible/inventory/lab/hosts.yml`)* | `192.168.20.201` |
| `1972-master-1` | `d8:3a:dd:eb:19:52` | `192.168.20.202` |
| `1972-worker-1` | `2c:cf:67:40:d6:92` | `192.168.20.203` |
| `1972-worker-2` | `2c:cf:67:40:d7:a1` | `192.168.20.204` |

Keep the DHCP pool at `.100–.199` and leave `.240–.250` free for MetalLB. Those
three ranges must not overlap; an overlap presents as a service that works
until the pool hands out an address MetalLB is already announcing.

## 2. Flash vanilla, then drop in cloud-init

Do **not** use the Imager's advanced-options panel. It writes cloud-init
`user-data` to the boot partition, which is exactly what's done by the templates.

```bash
make bootstrap-render HOST=1972-master-1
```

Copy `build/1972-master-1/user-data` and `network-config` onto the FAT boot
partition (`system-boot` when mounted on a workstation) and boot.

## 3. Pi config

### Memory cgroups

The three **kubernetes cluster** nodes need `cgroup_enable=memory cgroup_memory=1` in
`/boot/firmware/cmdline.txt`. The rendered `user-data` appends it in `bootcmd`
and reboots once, so this is handled — but if a node was imaged some other way,
`ansible/roles/kube_prereqs` asserts on it and fails with a clear message
rather than letting the kubelet fail with an unclear one.

**One line, no wrapping.** A wrapped `cmdline.txt` is an unbootable Pi that
needs a monitor and a keyboard.

### Swap

`swapon --show` must be empty. `ansible/roles/common` masks `swap.target`
rather than just running `swapoff`, because a plain `swapoff` comes back on
reboot and the kubelet then refuses to start with an error that does not
obviously mention swap.

## 4. Verify before going further

```bash
make test-network       # the §2.3 matrix — run it on the Pi itself
```

Do not install anything until this passes. Every test in it corresponds to a
failure that is much harder to diagnose later — see
[01-network-validation.md](01-network-validation.md).

## 5. Converge

```bash
make deploy-nodes
```

From here on, nothing about a node is configured by hand.
