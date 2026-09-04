# Build 0003 — SSH cutover retry

**Dates:** 2026-09-04 → *(open)*
**Runbook followed:** [`docs/REBUILD.md`](../REBUILD.md) @ `55e1e69`
**Target versions:** k8s `1.37.0`, etcd `3.7.1-0`, Cilium `1.20.1`
**Outcome:** *(open)*

---

## Why this build

[Build 0002](0002-k8s1.67.md) failed inside Phase E: a local-only fix to the
SSH CA cutover never reached the branch `deploy-nodes` (CI) actually runs
against, which locked out `1972-master-1`, `1972-worker-1`, and
`1972-worker-2` with no CI or SSH path back in — recovery needed pulling SD
cards. Rather than repair that cluster in place, this is a full re-image and
re-run, on the same target versions, with the root cause now fixed in
[`docs/REBUILD.md`](../REBUILD.md#phase-e--identity) itself rather than only
in a postmortem. The claim this build needs to prove is narrower than
0002's: not just that the runbook works through Phase D (0002 already showed
that), but specifically that Phase E's new gate actually prevents the same
lockout on a second attempt.

## Carried in

From [build 0002](0002-k8s1.67.md#carried-into-build-0003):

- [ ] **Prove the runbook end to end, including Phase E and F.** 0002's
      original purpose, still unmet.
- [ ] **Land `bootstrap/cloud-init/render.sh`'s fix.** Held uncommitted
      through all of 0002; still correct, still not on `main`.
- [ ] **Land `render.sh` and any future SSH-trust-affecting fixes in their
      own PR immediately**, not batched with other work — the direct lesson
      from 0002's failure, applied proactively this time.
- [ ] **Note the check-mode false-negative** (`docker-ce`/`kubelet` "no
      package matching" under `CHECK=1`) somewhere steps 1.3/3.2 can warn
      about it.
- [ ] **Document Argo CD manual-sync semantics** (`prune: true` not
      inherited by manual `operation.sync`; identical-content patches are
      no-ops) in `cluster/README.md`.
- [ ] **Add the `cilium-operator` restart step explicitly to Phase D**,
      right after `bootstrap-argocd`.
- [ ] **Kubescape post-install pair** — only the pre-install half exists
      from 0002; capture both this time.
- [ ] **`eightbitsaxlounge/server` deletion** and **`apps/` ApplicationSet
      being empty** — both still out of scope, carried forward unchanged
      since build 0001.

## Deviations from the runbook

**Fill this in as you go.** Reconstructed afterwards it is worth nothing — the
detail that matters is the one that seemed too small to write down at the time.

| Step | What the runbook said | What actually happened | Fix |
|---|---|---|---|
| 1.1 | — (not a documented step) | Same as build 0002: re-imaging changed all four host SSH keys again, `main`'s committed `known_hosts` was stale | `make known-hosts`, regenerated and committed before it could block anything — [PR #125](https://github.com/nineteenseventytwo/nineteenseventytwo-platform/pull/125), merged |
| 1.2 | `make test-network` | Ran it from the workstation first, out of habit — got 3 false failures (`addr=none gw=none`, MTU, VLAN 30/40 reachable) because the script needs to run *from a Pi on VLAN 20's access port*, not the workstation. Not a real regression, just the wrong execution context | Cloned the repo fresh onto `1972-console-1` (its own runner checkout didn't exist yet — nothing had run there since the re-image) and ran it there: 10/10 real checks pass, 2 skipped as documented |
| 1.3 → 2.2 | `deploy-nodes` runs once per rebuild before CI exists | A *second*, CI-triggered `deploy-nodes.yml` run (queued at 05:43 from PR #124's merge, before any runner existed) got picked up the instant `deploy-cicd` registered the new runners, racing my own manual `deploy-nodes.yml` dispatches in the same `concurrency: group: deploy-nodes` lane. I mistook the legitimately-running queued job for an orphaned one and cancelled it before realizing it was doing real, correct work | No lasting harm — Ansible is idempotent and the nodes were already fully converged from the direct local run beforehand. Worth calling out as a real gotcha for next time: check `gh run list --json ... event,createdAt` for anything queued *before* `deploy-cicd` finishes before assuming a stuck run is orphaned |
| 3.4 | `AWS_PROFILE=nineteenseventytwo-platform-prod make publish-oidc` | SSO session had expired since build 0002 (`Token has expired and refresh failed`) | `aws sso login --profile nineteenseventytwo-platform-prod`, then retried clean — both discovery endpoints verified live (200) |
| 3.4 (cloud side) | `publish-discovery.sh` suggests setting `publish_cluster_oidc=true` and applying | Flag already defaults `true` in `variables.tf`; a `terraform plan` came back **"No changes."** — the OIDC provider is keyed to the issuer URL and TLS thumbprint, not the cluster's actual signing keys, so it survives a rebuild without needing re-apply even though `kubeadm init` rotates the signing keys every time | Nothing to fix — confirmed via read-only `plan`, no `apply` needed |
| 3.3 | Store kubeconfig as org secret `KUBECONFIG` | This is a cluster-admin credential going into an org-wide GitHub secret — flagged for explicit sign-off rather than run automatically | User set it directly rather than have it run through an agent session |

## PRs

| Range | Theme |
|---|---|
| [#125](https://github.com/nineteenseventytwo/nineteenseventytwo-platform/pull/125) | Regenerate `known_hosts` for the re-imaged nodes |
| [#126](https://github.com/nineteenseventytwo/nineteenseventytwo-platform/pull/126)–[#127](https://github.com/nineteenseventytwo/nineteenseventytwo-platform/pull/127) | Throwaway self-hosted-runner proof, then removed |

Counts so far: `fix/` 1 · `feat/` 0 · `chore/` 1 · `test/` 1 · `docs/` 0 · total 3.

Compare the `fix/` share against build 0002's 8/10 (80%). Anything at or
above that, on a rebuild that starts from a runbook 0002 already corrected
through Phase D, means this log's own carried-in items did not actually make
it into the config.

## Evidence captured

- [x] Kubescape NSA baseline against the **empty hardened cluster** →
      `docs/builds/0003-baseline-nsa.json` — 78/100, matches build 0002's
      pre-install score exactly (same hardening config, same k8s/Cilium
      versions — expected, not a coincidence)
- [ ] Post-install Kubescape scan for the before/after pair
- [ ] `make test-network` output (all 12)
- [ ] `make test-nodes` across all four hosts
- [ ] `make verify-default-deny` → 0
- [ ] `make verify-irsa` → assumed-role identity
- [ ] `kubectl -n argocd get applications` → all Synced/Healthy

## What broke that the runbook did not predict

The section the next build actually reads. One entry per surprise: the symptom,
why it was not obvious, and — most importantly — **where the fix landed** so it
cannot recur. A fix that landed only in this log is not a fix.

## Carried into build 0004

- [ ]
