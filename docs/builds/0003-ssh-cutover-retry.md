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
| | | | |

## PRs

| Range | Theme |
|---|---|
| | |

Counts at close: `fix/` __ · `feat/` __ · `chore/` __ · `docs/` __ · total __.

Compare the `fix/` share against build 0002's 8/10 (80%). Anything at or
above that, on a rebuild that starts from a runbook 0002 already corrected
through Phase D, means this log's own carried-in items did not actually make
it into the config.

## Evidence captured

- [ ] Kubescape NSA baseline against the **empty hardened cluster** →
      `docs/builds/0003-baseline-nsa.json`
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
