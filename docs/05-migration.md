# 05 — Migration from `eightbitsaxlounge/server`

Not a phase like 00–03 — a cutover ledger that spans all of them. Use it to
map an old script or manifest to where it landed here, and to track what's
still open before `eightbitsaxlounge/server` can be deleted. **Do not delete
anything there until the replacement rebuilds a node end to end.**

**Done as of 2026-09-12.** Every row below is resolved, `eightbitsaxlounge`'s
six services run in `apps/eightbitsaxlounge/{dev,prod}` reconciled by Argo CD,
and `eightbitsaxlounge/server` — along with `security/`, `monitoring/`, and
the per-service ansible deploy playbooks it left behind in the app repo — is
deleted. One deviation from this doc's own original plan, decided at
migration time rather than here: `server/README.md` was never replaced with
a stub pointing at `docs/` — the whole directory was removed outright instead
(see the mapping table's last row). `docs/plan/08-eightbitsaxlounge-
migration.md` is the actual execution record for the app-layer half of this
work (Phase 6.1–6.2); this doc's mapping table and the platform-bootstrap
sequencing below it are kept as the historical ledger.

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

- [x] Every row in the mapping table is either migrated or explicitly kept
      in the app repo
- [ ] A full rebuild has run end to end: imaging → `deploy-nodes` →
      `deploy-cicd` → `deploy-cluster` → `bootstrap-argocd` — this is a
      platform-wide gate, not specific to eightbitsaxlounge; not verified as
      part of this app's migration
- [x] `eightbitsaxlounge` has no self-hosted `pull_request` runner (step 2)
      — confirmed 2026-09-12: every workflow triggers on `workflow_dispatch`
      and/or `push` only
- [x] ~~`server/README.md` is replaced with a stub pointing at `docs/`~~ —
      superseded: `server/` was deleted outright instead (2026-09-12)

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
VLAN 20, and the ADR-0010 gap closed. **Met as of 2026-09-12** — `server/`
was deleted outright rather than left as a stub; see the note at the top of
this doc.

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
| `k8s-ingress-nginx.yaml` | `cluster/ingress-nginx/`, then deleted | Ran as a pinned-LoadBalancer-IP Ingress controller for a while; superseded entirely by Cilium Gateway API ([ADR-0015](decisions/ADR-0015-cilium-gateway-api.md), 2026-09-02) once ingress-nginx itself was retired upstream. This row was still pointing at the deleted `cluster/ingress-nginx/` until 2026-09-12 — a stale leftover from before ADR-0015, not corrected at the time |
| `chat/chat-deploy.yaml`, `midi/midi-api-deploy.yaml`, `overlay/overlay-deploy.yaml`, `state/state-nats.yaml`, `db/db-couchdb.yaml` | `apps/eightbitsaxlounge/{dev,prod}/` | **New as of [ADR-0012](decisions/ADR-0012-platform-owns-app-workloads.md).** Not a mechanical copy — each needs its `image:` repointed at GHCR, its resource requests sized to fit inside the quota in `policy/tenants/eightbitsaxlounge.yaml`, and any Secret it reads converted to an `ExternalSecret` against Vault. Done per-service, in dependency order `db → state → data → midi → overlay → chat`; see [`apps/README.md`](../apps/README.md) and `docs/plan/08-eightbitsaxlounge-migration.md`. All six ansible deploy playbooks listed here, and their Makefile `deploy` targets, were deleted from the app repo once every one of them was confirmed dead (2026-09-12) |
| `security/security-deploy.yaml` (app repo) | Deleted, superseded | Hand-rolled Trivy CronJob with a PAT-based SARIF upload and one hardcoded image list. Superseded by two things that already exist and are more complete: the app repo's own `pr.yml` `security` job (Checkov + Trivy fs, every PR) for what it builds, and this repo's `image-vuln-scan.yml` for what's actually deployed — it scans every unique image reference running cluster-wide, weekly, with Slack alerting, which already includes every eightbitsaxlounge image since they run in this cluster |
| `chat/chat-set-environment.yaml`, `midi/midi-data-*.yaml`, `midi/midi-request-*.yaml` | Stays in the app repo | Data/runtime operations against a running deployment, not cluster config |
| `monitoring/k8s-monitoring.yaml` (app repo) | Deleted, superseded | `cluster/monitoring/` (kube-prometheus-stack) already scrapes every namespace. App-specific Grafana Cloud dashboards are being rebuilt by hand separately — deliberately not this repo's or that one's concern to own |
| `init-pc.yaml` | Ran once, then retired | The Windows/PowerShell SSH setup for the PC's one-time key authorization. Not carried forward as a live file — `midi-pc-deploy.yaml` (app repo) is what actually deploys to the PC on every release, and already existed independently of this script |
| `init-gpu-node.yaml`, `init-gpu-access.yaml` | Out of scope | [ADR-0011](decisions/ADR-0011-arm64-only.md) — stays with composer for now |
| `scripts/ansible-vault-init.sh` | Retired | Replaced by SOPS+age ([ADR-0008](decisions/ADR-0008-sops-age.md)) |
| `setup-tailscale.yaml` | Not carried over | Decide separately; it overlaps with the VLAN 10 → VLAN 20 SSH path this design already handles |
| `shutdown.yaml` | Deleted, not ported | Ordered worker-then-control-plane shutdown for the old cluster, driven by the app repo's own `server-shutdown.yaml` workflow. [08-eightbitsaxlounge-migration.md's M1](plan/08-eightbitsaxlounge-migration.md) decided to port this to `ansible/playbooks/` here; at actual migration time (2026-09-12) the decision changed to deleting it outright and deciding a replacement later — nothing in this repo does an ordered shutdown today |
| `roles/helm` | Already covered | `ansible/roles/kube_control_plane` already installs Helm the same way |
| `roles/k8s_iptables` | Already covered | iptables package + bridge-nf-call/sysctl setup for kubeadm prerequisites — `ansible/roles/kube_prereqs` already does this |
| `files/manifests/nginxtest.yaml` | Retired | An ad-hoc `kubectl apply` smoke-test Deployment, never part of the architecture |
| `k8s/` | Retired | Empty for as long as this table has tracked it — nothing to map |
| `scripts/containerd-reinstall.sh`, `scripts/dhcp-restart.sh`, `scripts/dockerSource.sh`, `scripts/gitlabs-runner.sh`, `scripts/kubernetes-checkcert.sh` | Retired | Ad-hoc troubleshooting/setup scripts, not part of any playbook run. `dhcp-restart.sh` and `dockerSource.sh`'s own functions are already covered above (Kea/OPNsense DHCP, `ansible/roles/docker`); `gitlabs-runner.sh` set up a `gitlab.local` hosts entry for tooling this platform never uses (GitHub Actions throughout); the other two were manual fix-up/diagnostic tools with no durable replacement needed |
| `server/README.md` | Deleted, not stubbed | The whole directory was removed outright (2026-09-12) rather than left as a stub pointing here — see the note at the top of this doc |

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
