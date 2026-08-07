# 05 — Migration from `eightbitsaxlounge/server`

Cut over in this order. **Do not delete anything until the replacement rebuilds
a node end to end.**

| Current | Destination | Notes |
|---|---|---|
| `scripts/init.sh` | `ansible/roles/common` | Drops installing Ansible on the host entirely — container-first |
| `scripts/github-runner.sh` | `ansible/roles/runner_host` + compose template | Replaced by org-scoped, App-authenticated, ephemeral containers |
| `init-nodes.yaml`, `init-console.yaml` | `ansible/playbooks/10-bootstrap-nodes.yml` | Console no longer needs to be a DHCP server — Kea on OPNsense does that ([ADR-0009](decisions/ADR-0009-dhcp-authority.md)) |
| `init-docker.yaml` | `ansible/roles/docker` | Adds daemon log caps and the three-way proxy config |
| `init-kubernetes.yaml`, `k8s-*.yaml` | `cluster/` values + `ansible/playbooks/30-cluster.yml` | Flannel manifest dropped; Cilium replaces it |
| `k8s-flannel.yaml` | Deleted | See [ADR-0003](decisions/ADR-0003-cni-cilium-no-mesh.md) |
| `k8s-metallb.yaml` | `cluster/metallb/` | Pool moves from `192.168.68.240-250` to `192.168.20.240-250` |
| `k8s-namespaces.yaml` | `policy/tenants/eightbitsaxlounge.yaml` | Namespace + quota + limits + default-deny. Gains the pieces the original never had (PSS labels, ResourceQuota) |
| `k8s-storage.yaml` | `cluster/longhorn/` | Now a pinned Helm release with explicit replica and rebuild limits |
| `k8s-ingress-nginx.yaml` | `cluster/ingress-nginx/` | Gains a pinned LoadBalancer IP so Unbound overrides stay valid |
| `chat/chat-deploy.yaml`, `midi/midi-api-deploy.yaml`, `security/security-deploy.yaml`, `overlay/overlay-deploy.yaml`, `state/state-nats.yaml`, `db/db-couchdb.yaml` | `apps/eightbitsaxlounge/{dev,prod}/` | **New as of [ADR-0012](decisions/ADR-0012-platform-owns-app-workloads.md).** Not a mechanical copy — each needs its `image:` repointed at GHCR, its resource requests sized to fit inside the quota in `policy/tenants/eightbitsaxlounge.yaml`, and any Secret it reads converted to an `ExternalSecret` against Vault. Do this per-service, verifying each one deploys before moving to the next; see [`apps/README.md`](../apps/README.md). |
| `chat/chat-set-environment.yaml`, `midi/midi-data-*.yaml`, `midi/midi-request-*.yaml` | Stays in the app repo | Data/runtime operations against a running deployment, not cluster config |
| `monitoring/k8s-monitoring.yaml` (app repo) | Superseded | `cluster/monitoring/` (kube-prometheus-stack) already scrapes every namespace; check for app-specific dashboards worth keeping before deleting |
| `init-pc.yaml` | Keep in the app repo | The Windows/PowerShell SSH setup is still needed for `midi-api`; the PC is on a tagged trunk (VLAN 10 Windows / VLAN 20 Linux) |
| `init-gpu-node.yaml`, `init-gpu-access.yaml` | Out of scope | [ADR-0011](decisions/ADR-0011-arm64-only.md) — stays with composer for now |
| `scripts/ansible-vault-init.sh` | Retired | Replaced by SOPS+age ([ADR-0008](decisions/ADR-0008-sops-age.md)) |
| `setup-tailscale.yaml` | Not carried over | Decide separately; it overlaps with the VLAN 10 → VLAN 20 SSH path this design already handles |
| `server/README.md` | Replaced by `docs/` | Leave a stub pointing here |

## Addressing change

The live inventory today is `192.168.68.0/24` (flat). This repo targets
`192.168.20.0/24` (VLAN 20). Node addresses map straight across — `.201`–`.204`
keep their last octet, so only the third octet changes.

Do the OPNsense work first and prove it with `tests/network-check.sh` before
reimaging anything. Reimaging a Pi onto a VLAN whose firewall rules are wrong
means a node that boots and is unreachable.

## Suggested sequencing

Fits the rebuild timeline's Phases 2–3.

| Week | Work | Done when |
|---|---|---|
| 1 | Create the org, move repos, create this repo, GitHub App, ADRs 0001–0004 | Org-level runner page exists |
| 2 | Cloud-init templates, image all four SSDs, run the §2.3 matrix | All four Pis reachable from VLAN 10 by key; VLAN 20 → VLAN 10 provably blocked |
| 3 | `common`/`hardening`/`docker` roles, `ansible-runner` image, `build-images.yml` | Image in GHCR, built without touching a Pi |
| 4 | Compose runner stack on console, `deploy-nodes.yml` | Push to main reconfigures a Pi with no human SSH |
| 5–6 | kubeadm + Cilium + join workers + default-deny + Kubescape baseline | Empty hardened cluster; before/after scan committed |
| 7 | Argo CD, MetalLB, ingress-nginx, cert-manager, Longhorn | First HTTPS ingress with a real Let's Encrypt certificate |
| 8 | Vault + KMS auto-unseal + ESO; migrate SOPS secrets in | Nothing sensitive left in GitHub except the age key and the App key |
| 9 | ARC scale sets; SSH CA cutover; tenant namespace + quota; migrate the app's Deployments into `apps/eightbitsaxlounge/` | eightbitsaxlounge running in-cluster, reconciled by Argo CD, with no cluster credential of any kind in the app repo |

## Do this in week 1, not week 9

[ADR-0010](decisions/ADR-0010-fork-pr-self-hosted-runners.md): `eightbitsaxlounge`
is public with self-hosted runners attached today. Audit its workflows for
`runs-on: self-hosted` on any `pull_request` trigger and route those to hosted
runners. That is a live code-execution path into the lab VLAN, and it does not
wait for the migration.

## Still open

Questions this repo does not answer, carried forward from the plan:

1. **`1972-console`'s MAC address** — the board was replaced (RPi 4/1 GB →
   RPi 5/2 GB/SSD, matching the cluster nodes). `ansible/inventory/lab/hosts.yml`
   has a placeholder; run `ip a` after first boot, update it, and match the Kea
   reservation for `192.168.20.201` before rendering its cloud-init.
2. **`.sops.yaml` recipients** — replace both placeholders before the first
   encrypt.
3. **KMS key ID** in `cluster/vault/values.yaml`.
4. **Chart versions** in `cluster/*/values.yaml` were pinned when this repo was
   written. Verify with `helm search repo <chart> --versions` before the first
   apply; the `helm` lint job will catch a values key the pinned version does
   not have.
