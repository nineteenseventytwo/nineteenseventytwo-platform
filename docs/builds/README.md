# Build logs

One log per **cluster build** — a build being any run of
[`docs/REBUILD.md`](../REBUILD.md) that takes the lab from bare hardware (or
bare nodes) to Argo CD reconciling `cluster/` from `main`.

A build log is not a changelog and not a runbook. It is the record of *what
this particular build cost*: what the runbook said, what actually happened,
and what the difference taught us. The runbook is corrected from the log —
that is the whole point of keeping one.

| # | Build | Dates | PRs | Outcome |
|---|---|---|---|---|
| [0001](0001-initial-build.md) | Initial build | 2026-08-20 → 2026-09-02 | 106 | Cluster live. Never rebuilt end to end, so the runbook is unproven. |
| [0002](0002-k8s1.67.md) | Kubernetes 1.37 rebuild | 2026-09-03 → 2026-09-04 | 10 | **Failed.** Phase E SSH cutover locked out 3 of 4 nodes with no CI/SSH recovery path; abandoned for a re-image rather than repaired in place. |
| [0003](0003-ssh-cutover-retry.md) | SSH cutover retry | 2026-09-04 → *(open)* | | In progress — same target versions as 0002, Phase E gate now enforced in REBUILD.md |

## Why a log per build, not a single changelog

Git already records every change. What git does not record is the shape of a
build: that build 0001 spent **54 of its 106 PRs on `fix/`**, that eleven of
those were the same class of problem (a NetworkPolicy nobody predicted), and
that the fix landed in the config so build 0002 should not pay for it again.

That is the number to watch. A healthy second build has few `fix/` PRs and
mostly `feat/` ones — PRs that move *through* the runbook rather than repair
the ground under it. If build 0002 is another wall of `fix/`, the lesson from
0001 did not actually get written down anywhere the config could enforce it.

## Writing one

Copy [`TEMPLATE.md`](TEMPLATE.md) to `NNNN-short-name.md`, add a row above,
and **open it at the start of the build, not the end**. A log written
afterwards records what you remember; a log written during records what
happened. The `Deviations` table in particular is worthless if it is
reconstructed.

Close the log when the build's definition of done in
[`docs/REBUILD.md`](../REBUILD.md#definition-of-done) is met, then move
anything still open into the next build's `Carried in` section rather than
leaving it dangling here.
