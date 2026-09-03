# Build NNNN — <name>

**Dates:** YYYY-MM-DD → *(open)*
**Runbook followed:** [`docs/REBUILD.md`](../REBUILD.md) @ `<commit>`
**Target versions:** k8s `<x.y.z>`, Cilium `<x.y.z>`
**Outcome:** *(open)*

---

## Why this build

One paragraph. What forced it — hardware change, version bump, a rehearsal, a
recovery. If it is a rehearsal, say what claim it is meant to prove.

## Carried in

From the previous build's `Carried into` section. Copy the items across rather
than linking to them, so this log stands alone.

- [ ]

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

Compare the `fix/` share against the previous build. A rising share means the
previous build's lessons did not make it into the config — say so here rather
than in the next build's postmortem.

## Evidence captured

- [ ] Kubescape NSA baseline against the **empty hardened cluster** →
      `docs/builds/NNNN-baseline-nsa.json`
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

## Carried into build NNNN+1

- [ ]
