# ADR-0010: Route `pull_request` jobs to hosted runners on public repos

**Status:** Accepted
**Date:** 2026-08-07

## Context

`nineteenseventytwo-eightbitsaxlounge` is **public** and has self-hosted runners
attached. That combination is a documented remote code execution path: a fork
pull request can execute arbitrary code on a machine sitting inside VLAN 20 —
a machine with SSH access to every cluster node.

This is a live exposure today, not a hypothetical about the new design.

The countervailing consideration is real: the public repo has showcase value.

## Decision

Keep `eightbitsaxlounge` **public**. Route all `pull_request`-triggered jobs to
GitHub-hosted runners. Self-hosted labels appear only on jobs triggered by
`push` to protected branches, or by `workflow_dispatch`.

## Consequences

- The showcase is preserved.
- A fork PR runs on GitHub's infrastructure with a read-only `GITHUB_TOKEN` and
  no path to the lab network.
- **This must be enforced per workflow, in every workflow, forever.** It is a
  convention, not a control — one `runs-on: self-hosted` in a `pull_request`
  job reopens the hole silently. That is the weakness of this decision and the
  reason it is written down.
- Belt-and-braces, and worth doing regardless:
  - Settings → Actions → **Require approval for all external contributors**.
  - Branch protection on `main` so `push` triggers cannot come from a fork.
- Deployment jobs must not be triggerable by `pull_request` at all — they should
  key off `push` to `main` or `workflow_run` following a successful build.
- This repo is unaffected: it is private ([ADR-0002](ADR-0002-private-repo.md)),
  so the path does not exist here.

## Action required this week

This is not a future-phase item. Until the routing is in place,
`eightbitsaxlounge` has a fork-PR code execution path into the lab VLAN. Audit
its existing workflows for `runs-on: self-hosted` on any `pull_request` trigger
before anything else in the migration.

## Alternatives considered

**Make `eightbitsaxlounge` private.** Strongest mitigation — the path stops
existing rather than being routed around. Rejected to keep the showcase, and
the decision is revisitable at any time.

**Require approval for all outside collaborators, and keep self-hosted PR runs.**
Rejected as the primary control: it relies on a human correctly judging every
run, and approval fatigue is a well-documented failure mode. Kept as a secondary
layer.
