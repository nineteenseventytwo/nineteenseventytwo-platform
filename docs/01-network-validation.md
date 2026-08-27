# 01 — VLAN 20 validation

Run [`tests/network-check.sh`](../tests/network-check.sh) from a Pi on a VLAN 20
access port (switch ports 5–8, PVID 20) **before installing anything**, and
again after every firewall change.

```bash
tests/network-check.sh
```

## The matrix

| # | Test | Expected | Why it earns its place |
|---|---|---|---|
| 1 | Subnet and gateway | `192.168.20.x/24`, default via `.20.1` | Confirms the access port is actually PVID 20 |
| 2 | Gateway reachable | ping OK | Fails if the OPNsense rule protocol is **TCP** rather than **any** — ICMP is not TCP |
| 3 | DNS via Unbound | `dig github.com @192.168.20.1` resolves | Everything downstream assumes name resolution |
| 4 | Egress TCP | `curl -I https://ghcr.io` → 200/301 | The registry is where every image comes from |
| 5 | Path MTU | `ping -M do -s 1472 1.1.1.1` OK | An MTU problem here resurfaces months later as "some HTTPS sites hang" |
| 6 | arm64 archive | `curl -I http://ports.ubuntu.com` → 200 | **`ports.ubuntu.com`, not `archive.ubuntu.com`** — easy to miss in a Squid allowlist |
| 7 | VLAN 20 → VLAN 10 **denied** | timeout | The isolation the whole design rests on |
| 8 | VLAN 20 → VLAN 30/40 **denied** | timeout | Same |
| 9 | VLAN 10 → VLAN 20 SSH | connects | Run from the workstation |
| 10 | VLAN 10 → VLAN 20 API | `nc -vz .202 6443` open | Run from the workstation, once the cluster exists |
| 11 | Intra-VLAN 20 | Pi → Pi ping works | And note the firewall **never sees this traffic** |
| 12 | Unbound overrides for lab tool hostnames | `dig argocd/vault/grafana.eightbitsaxlounge.com @192.168.20.1` → `192.168.20.240` | The overrides in the section below, actually checked. Skipped for months on the first build of this cluster — every one of Phase C/D's docs happened to reach these hostnames through a `curl --resolve` or `/etc/hosts` workaround instead, until CI's own certificate signing needed one and had none available (docs/plan/05-provisioning-completion-plan.md WP-3.1) |

Tests 9 and 10 report as *skipped* on a Pi rather than silently passing —
direction matters and a test that cannot run should say so.

## Test 11 is the important one conceptually

Pi-to-Pi traffic on VLAN 20 is switch-local. OPNsense never sees it, so no
firewall rule can constrain it. Inter-workload isolation is therefore a
**NetworkPolicy** problem, which is why [`policy/`](../policy/) applies
default-deny to every namespace before anything is deployed, and why the CNI
had to become Cilium — Flannel cannot enforce NetworkPolicy at all.

## OPNsense rules this implies

- Replace `Allow Trusted to any` with `Trusted → !Internal_Networks` (internet),
  plus explicit `Trusted → Lab_Nodes` on 22, 6443, 443.
- `Lab → !Internal_Networks` (internet only), protocol **any** — not TCP, or
  test 2 fails and you spend an evening on it.
- Reserve `192.168.20.240–250` for MetalLB; keep the Kea pool (`.100–.199`) and
  the node reservations (`.201–.204`) clear of it.
- Unbound host overrides for `1972-console-1`, `1972-master-1`, `1972-worker-1`,
  `1972-worker-2` under `eightbitsaxlounge.com` (matches the fqdn cloud-init
  renders: `{{ inventory_hostname }}.{{ lab_domain }}`), plus the internal
  tool hostnames used in `cluster/*/values.yaml` — `argocd.`, `vault.`,
  `grafana.` — so they resolve on VLAN 20 without waiting on public DNS
  propagation.

  **Concretely, three overrides** (Services → Unbound DNS → Overrides), each a
  Host record pointing at the pinned ingress LB address
  (`cluster/ingress-nginx/values.yaml`'s `loadBalancerIP`):

  | Host | Domain | Type | IP |
  |---|---|---|---|
  | `argocd` | `eightbitsaxlounge.com` | A | `192.168.20.240` |
  | `vault` | `eightbitsaxlounge.com` | A | `192.168.20.240` |
  | `grafana` | `eightbitsaxlounge.com` | A | `192.168.20.240` |

  **This is easy to skip without noticing**, and did get skipped on the first
  build of this cluster: `tests/network-check.sh 12` is the check, not the
  five Phase C/D docs that each happen to reach these hostnames some other
  way. Run it after adding the overrides, before assuming they're live —
  Unbound's cache means a browser or `curl` that already resolved one of
  these names elsewhere can look correct for a while regardless.

## Squid allowlist

Not enforced yet. Write it now so Phase B does not fight it later. The minimum
set for this repo to function:

```
ports.ubuntu.com            security.ubuntu.com
ghcr.io                     pkg-containers.githubusercontent.com
registry-1.docker.io        production.cloudflare.docker.com    auth.docker.io
pkgs.k8s.io                 registry.k8s.io
pypi.org                    files.pythonhosted.org
github.com                  objects.githubusercontent.com       api.github.com
quay.io                     helm.sh
```

When you do enforce it, **three separate proxy configs** are needed and missing
any one of them produces a different confusing symptom:

| Config | Where | Symptom if missed |
|---|---|---|
| Shell environment | `/etc/profile.d/10-egress-proxy.sh` | `curl` works for you, `apt` does not |
| Docker **daemon** | `/etc/systemd/system/docker.service.d/proxy.conf` | `curl` works, `docker pull` hangs |
| containerd | `/etc/systemd/system/containerd.service.d/proxy.conf` | `docker pull` works, pods stay `ImagePullBackOff` |

All three are handled by `ansible/roles/docker` and `ansible/roles/kube_prereqs`;
set `egress_proxy_enabled: true` in group_vars to turn them on.
