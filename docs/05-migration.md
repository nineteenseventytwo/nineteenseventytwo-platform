# 05 — Migration from `eightbitsaxlounge/server`

Not a phase like 00–03 — a cutover ledger that spans all of them. Use it to
map an old script or manifest to where it landed here, and to track what's
still open before `eightbitsaxlounge/server` can be deleted. **Do not delete
anything there until the replacement rebuilds a node end to end.**

## Prerequisites

- None specific to this doc — it tracks the same sequence as
  [00](00-bootstrap.md)–[03](03-cluster.md). The one thing to do **before**
  any of those: the OPNsense addressing change below, proved with
  `make test-network`.

## 1. Addressing change — do this before reimaging anything

The live inventory today is `192.168.68.0/24` (flat). This repo targets
`192.168.20.0/24` (VLAN 20). Node addresses map straight across —
`.201`–`.204` keep their last octet, so only the third octet changes.

Do the OPNsense work first and prove it with `tests/network-check.sh`
([01-network-validation.md](01-network-validation.md)) before reimaging
anything. Reimaging a Pi onto a VLAN whose firewall rules are wrong means a
node that boots and is unreachable.

## 2. Close the live security gap — do this now, not at the end

[ADR-0010](decisions/ADR-0010-fork-pr-self-hosted-runners.md):
`eightbitsaxlounge` is public with self-hosted runners attached today. Audit
its workflows for `runs-on: self-hosted` on any `pull_request` trigger and
route those to hosted runners. That's a live code-execution path into the
lab VLAN, and it doesn't wait for the rest of this migration.

## 3. Work through the mapping table

[Reference](#script--manifest-mapping) below maps every script and manifest
in the old repo to its replacement here (or "retired," or "stays in the app
repo"). Migrate app Deployments one service at a time, verifying each
deploys before moving to the next — see
[`apps/README.md`](../apps/README.md).

## Verify before deleting the old repo

- [ ] Every row in the mapping table is either migrated or explicitly kept
      in the app repo
- [ ] A full rebuild has run end to end: imaging → `deploy-nodes` →
      `deploy-cicd` → `deploy-cluster` → `bootstrap-argocd`
- [ ] `eightbitsaxlounge` has no self-hosted `pull_request` runner (step 2)
- [ ] `server/README.md` is replaced with a stub pointing at `docs/`

## Still open

- **KMS key ID** — `cluster/vault/values.yaml` still has
  `kms_key_id = "REPLACE_WITH_KMS_KEY_ID"`. Needed before Tier 2 in
  [04-secrets.md](04-secrets.md#3-tier-2--vault--kms-auto-unseal--eso).
- **Chart versions** in `cluster/*/values.yaml` were pinned when this repo
  was written. Verify with `helm search repo <chart> --versions` before the
  first apply of each — the `helm` lint job catches a values key the pinned
  version doesn't have, not a version that's since been yanked.
- **ADR-0010 audit** (step 2) — confirm closed, don't assume it from this
  doc.

## Definition of done

Every row in the mapping table resolved, the addressing change proved on
VLAN 20, and the ADR-0010 gap closed. At that point `server/` is a stub and
`eightbitsaxlounge/server`'s scripts can be deleted.

---

## Reference

### Script / manifest mapping

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

### Suggested sequencing

Fits the rebuild timeline's Phases 2–3. Kept as the original week-by-week
estimate — not a live status tracker.

| Week | Work | Done when |
|---|---|---|
| 1 | Create the org, move repos, create this repo, GitHub App, ADRs 0001–0004 | Org-level runner page exists |
| 2 | Cloud-init templates, image all four SSDs, run the §2.3 matrix | All four Pis reachable from VLAN 10 by key; VLAN 20 → VLAN 10 provably blocked |
| 3 | `common`/`hardening`/`docker` roles, `ansible-runner` image, `image-ansible-runner-build.yml` | Image in GHCR, built without touching a Pi |
| 4 | Compose runner stack on console, `deploy-nodes.yml` | Push to main reconfigures a Pi with no human SSH |
| 5–6 | kubeadm + Cilium + join workers + default-deny + Kubescape baseline | Empty hardened cluster; before/after scan committed |
| 7 | Argo CD, MetalLB, ingress-nginx, cert-manager, Longhorn | First HTTPS ingress with a real Let's Encrypt certificate |
| 8 | Vault + KMS auto-unseal + ESO; migrate SOPS secrets in | Nothing sensitive left in GitHub except the age key and the App key |
| 9 | ARC scale sets; SSH CA cutover; tenant namespace + quota; migrate the app's Deployments into `apps/eightbitsaxlounge/` | eightbitsaxlounge running in-cluster, reconciled by Argo CD, with no cluster credential of any kind in the app repo |
