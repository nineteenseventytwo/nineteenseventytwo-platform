# Build 0001 — Initial build

**Dates:** 2026-08-20 → 2026-09-02
**Runbook followed:** none — [`docs/REBUILD.md`](../REBUILD.md) was written *from* this build
**Outcome:** cluster live and reconciling. **Never rebuilt end to end**, so the
sequence this build produced is documented but unproven.
**PRs:** [#1–#107](https://github.com/nineteenseventytwo/nineteenseventytwo-platform/pulls?q=is%3Apr+is%3Amerged) (106 merged; #15 closed unmerged)

---

## What this build was

The migration off `eightbitsaxlounge/server`: four Raspberry Pi 5s moved from a
flat `192.168.68.0/24` network with Flannel onto VLAN 20 with a kubeadm cluster,
Cilium, and Argo CD reconciling everything from git. It ran as a continuous
two-week push rather than a planned build, which is why it produced a hundred
PRs and no runbook until the end.

It is the reference point every later build is measured against, and the honest
summary is that **half of it was repair work on ground that should have been
solid before the first `kubeadm init`**.

## The numbers

| | |
|---|---|
| Merged PRs | 106 |
| `fix/` | **54** |
| `feat/` | 21 |
| `chore/` | 10 |
| `docs/` | 7 |
| Unprefixed (early, before the convention settled) | 14 |
| Elapsed | 14 days |

54 of 106. That single ratio is the finding of this build, and everything below
is an attempt to make the next one's ratio different.

---

## Chronology

### #1–#17 · Getting Ansible to reach the hardware at all (2026-08-20 → 08-21)

Before a single Kubernetes component was installed, the runner image and the
Ansible path to the nodes had to be made to work. The non-root runner image
(#2–#4) broke SSH host-key verification under an arbitrary `--user` UID (#5).
`containerd.io` was not reachable without Docker's own apt repo (#6), which then
had to migrate to `deb822_repository` (#8). Helm and `helm-diff` were not on the
control plane (#10, #14). Values and policy files were referenced at paths that
existed on the workstation but not on the node the playbook actually ran on
(#11, #13).

The one with teeth was **#16**: the hardening role's `rp_filter` and `ufw`
sysctls silently broke Cilium pod networking. A security baseline and a CNI
disagreeing about the kernel's network stack, discovered only once pods could
not talk.

### #18–#38 · First Argo CD sync (2026-08-22)

A single day, twenty PRs. Argo CD came up and every assumption in `cluster/` met
the cluster for the first time: `KUBECONFIG` resolved relative (#21), Helm state
not persisted across container calls (#22, #28), the application-controller
OOMing on first sync (#25), Longhorn's pre-upgrade hook deadlocking a first sync
under GitOps (#27), worker nodes unlabelled for both scheduling and Longhorn's
disk creation (#29, #30).

And the first four of what became this build's dominant failure class: the
`default-deny` policy blocking traffic nobody had predicted — Argo CD and the
pod-identity-webhook to the apiserver (#23), same-namespace traffic within
`argocd` (#24), the whole `monitoring` namespace to the apiserver (#26),
apiserver-to-webhook admission calls needing `fromEntities` (#31).

### #36–#54 · Phase D, the SSH CA (2026-08-22 → 08-28)

Vault's SSH CA trusted on every node (#36), cutover tooling landed gated off
(#47), a Vault AppRole so CI could sign certificates without a human token
(#48), then three PRs of `sign-ci.sh` meeting reality — wrong filesystem
context (#50), then DNS and a UID mismatch, "both found live" (#51). Cutover
completed at #52; the legacy `ansible-*` keys retired.

This is the build's best-run phase, and the reason is visible in the PR
sequence: the risky change shipped **inert** (#47) and was flipped in its own
PR (#52) once the tooling around it was proven.

### #55–#78 · Evidence, observability, supply chain (2026-08-28 → 08-29)

Alertmanager to Slack (#55), and immediately three follow-ups — the null
receiver the Watchdog route depends on (#57), egress to Slack's webhook (#58),
and the DNS proxy rule Cilium's `toFQDNs` actually needs (#59). A real
kube-apiserver audit policy (#56). Prowler landed (#61) and took three fixes to
actually upload anything (#62–#64). `kubelet-csr-approver` closed the
kubelet-serving CSR gap (#65). Cosign keyless signing (#70). Tenant-scoped RBAC
and kubeconfig generation (#67).

**#60 is the one that matters for the next build:** the Kubescape NSA baseline,
captured and *labelled honestly as post-install* because the pre-install window
had already closed. 72/100 compliance, 93 High findings. See
[Carried in](#carried-into-build-0002).

### #79–#89 · Scanning and the version sweep (2026-09-01)

Scheduled vulnerability scanning for every running image (#79), which needed
three follow-ups of its own (#80–#82) and a fourth later (#104). Then a clean
sweep of chart pins in one sitting: Cilium, Vault, ESO, kube-prometheus-stack,
Argo CD, Prowler (#83–#89).

### #90–#103 · The Gateway API cutover (2026-09-01 → 09-02)

The most disciplined sequence in the build, and worth reading as a model.
Gateway API CRDs vendored *ahead* of the controller that needs them (#90),
Cilium's Gateway API support enabled (#92), kube-proxy-replacement prepared
inert then flipped (#93, #94 — "DO NOT MERGE ALONE, see body"), the shared
Gateway added (#95), then each consumer cut over one at a time with its own PR
and its own verification: Grafana (#97), Vault (#101), Argo CD's own UI (#102).
Only then was ingress-nginx removed and the decision recorded (#103,
[ADR-0015](../decisions/ADR-0015-cilium-gateway-api.md)).

It still cost three NetworkPolicy fixes discovered at runtime (#99, #100) and
three "perpetually OutOfSync" fixes (#91, #96, #98).

### #104–#107 · Tail (2026-09-02)

Vuln-scan orphaned findings (#104), kube-apiserver to v1.36.4 with etcd pinned
to 3.6.14-0 (#105), ResourceQuota/LimitRange for the infra namespaces (#106),
and Trivy exclusions for a per-file blind spot (#107).

---

## Where the 54 `fix/` PRs went

Grouped by the class of problem rather than the component, because the class is
what recurs.

| Class | PRs | Why it kept happening |
|---|---|---|
| **NetworkPolicy discovered at runtime** | #23, #24, #26, #31, #42, #44, #46, #58, #59, #99, #100 | Every new component needed egress nobody predicted. `policy/` and the component shipped in *separate* PRs, so the gap was only ever found by deploying. |
| **Runner image identity / permissions** | #2–#5, #9, #17, #18, #49, #50, #51 | Non-root, arbitrary UID, docker socket group, per-runner work directories — each surfaced one at a time, in production, over ten days. |
| **Ansible reaching or preparing the host** | #6, #8, #10, #11, #12, #13, #14, #16 | Missing packages, missing plugins, and files referenced at workstation paths from tasks that run on the node. |
| **Argo CD sync semantics** | #22, #27, #37, #39, #41, #91, #96, #98 | Hooks, server-side apply, OCI chart paths, and CRDs that read as perpetually OutOfSync. Argo CD does not behave like `helm install`, and the differences were each learned once. |
| **CI workflow follow-ups** | #57, #62, #63, #64, #80, #81, #82, #104, #107 | A workflow that looks right and is only proven by a scheduled run. `image-vuln-scan` alone took four. |
| **Makefile / local tooling** | #21, #28, #33, #38 | Relative paths, state directories created per-target, and quoting inside `kubectl` jsonpath. |

## What is now guarded, so it should not recur

These are the mechanisms this build produced. They are the reason to expect
build 0002 to be shorter — and the things to check are still working before
starting it.

- **`make verify-default-deny`** ([`tests/verify-default-deny.sh`](../../tests/verify-default-deny.sh))
  — asserts every namespace has `default-deny-all` or is on the explicit
  exemption list. Exists because "default-deny everywhere" was true of the
  README and not the cluster for months. Turns the largest failure class above
  into a check.
- **`make test-nodes`** ([`tests/goss/node.yaml`](../../tests/goss/node.yaml)) —
  the node properties whose absence produces a confusing failure somewhere else.
- **`make test-network`** ([`tests/network-check.sh`](../../tests/network-check.sh))
  — 12 tests, exit code is the failure count. Test 12 (Unbound overrides) was
  added *because* this build skipped it for months and paid for it later.
- **`make lint-helm`** — renders every pinned chart against its values file, so a
  values key the pinned version does not have fails in CI, not on the cluster.
- **`kube_control_plane` asserts the OIDC issuer** before it will run, and
  refuses if a running control plane disagrees with the inventory. This is the
  one-way door — `kubeadm init` fixes `--service-account-issuer` permanently.
- **`image-vuln-scan.yml`** — weekly scan of every image the cluster actually
  runs, so a chart pin going stale is visible without a manual sweep like
  #83–#89.
- **The "ship it inert" pattern** — #47/#52 and #93/#94 both landed a risky
  change disabled and flipped it in its own PR. It worked both times.

## Carried into build 0002

- [ ] **The Kubescape pre-install baseline.** Build 0001 missed the window
      entirely; `docs/baseline-nsa.json` is a post-install scan (2026-08-28,
      72/100, 93 High). Build 0002 reopens it — the scan against the **empty
      hardened cluster** is a numbered, gated step in
      [`docs/REBUILD.md`](../REBUILD.md), not a step in a component doc, because
      that is exactly how it got skipped.
- [ ] **Kubernetes 1.36.4 → 1.37.0.** The rebuild is the cheap place to test a
      minor bump; a rollback is a re-image rather than a downgrade in place.
      1.37.0 has no patch release yet — record what that costs.
- [ ] **Prove the runbook.** `docs/05-migration.md`'s definition of done and
      `docs/plan/05`'s WP-6 both require a full end-to-end run. Nothing in this
      build proves the README's central claim, and this build is 54 pieces of
      evidence that first contact finds what review does not.
- [ ] **`eightbitsaxlounge/server` deletion** — blocked on the mapping table in
      [`docs/05-migration.md`](../05-migration.md) reaching zero.
- [ ] **The SSH CA cutover left `main` in a state a rebuild cannot start from.**
      `hardening_ssh_trust_ca` and `hardening_ssh_retire_legacy_keys` are both
      `true` with `hardening_ssh_authorized_keys: []`, so the *first*
      `make deploy-nodes` of a from-scratch build empties `authorized_keys` on
      all three cluster nodes and points `TrustedUserCAKeys` at this cluster's
      `ca.pub` — whose private half dies with this cluster. The nodes become
      unreachable, and it fails on the *next* run rather than the one that
      caused it. Handled as a gate at
      [`REBUILD.md` step 0.7](../REBUILD.md#07-reset-the-ssh-trust-state--a-from-scratch-build-is-locked-out-without-this);
      worth a durable fix so the defaults do not encode one build's end state as
      the next build's start state.
- [ ] **`apps/` is still effectively empty** — the `100-apps` ApplicationSet has
      little to discover. Workload migration is the long tail from
      [`docs/plan/05`](../plan/05-provisioning-completion-plan.md) WP-5.

## The trap this build set for the next one

Build 0001's final state is committed to `main`, and for the SSH CA that state is
**post-cutover**. A rebuild starts pre-cutover. Nothing in the repo distinguishes
"the value that is correct for the running cluster" from "the value a build
starts at", so the two most irreversible flags in the hardening role read as
defaults when they are really the last step of a sequence.

A second instance of the same shape, found in the same pass: **Cilium's version
was pinned in three places and PR #83 updated two of them.**
`cilium_version` in the inventory stayed at `1.20.0` while
`cluster/cilium/values.yaml` and `00-cilium.yaml` went to `1.20.1`. The
inventory value is what `30-cluster.yml` installs *pre-Argo*, so a rebuild would
have installed 1.20.0 and had Argo CD upgrade the CNI to 1.20.1 during the first
sync — an unnecessary variable in the middle of a build, and invisible on a
running cluster because Argo had already converged it. Corrected in the version
prep for build 0002.

Both cases are the same class: **a value whose correct setting depends on where
in a build you are, stored somewhere that has no notion of build phase.** Worth
a pass over the rest of the inventory for others before build 0002 starts.

## What this build changed about the runbook

1. **There is one now.** The build was driven from `docs/00`–`07` plus two plan
   documents, and the ordering lived in nobody's head consistently. That is the
   direct cause of the missed Kubescape baseline.
2. **The baseline scan is a gate, not a suggestion.** It sits between "cluster is
   up and hardened" and "Argo CD gets the cluster", and the runbook says so in
   the position where skipping it is visible.
3. **NetworkPolicy is a pre-merge concern.** A component PR that adds egress
   without adding the policy for it is the single most repeated mistake here.
