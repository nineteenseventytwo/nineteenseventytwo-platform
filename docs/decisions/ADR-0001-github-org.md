# ADR-0001: Create a `nineteenseventytwo` GitHub organisation

**Status:** Accepted
**Date:** 2026-08-07

## Context

A self-hosted runner can be registered to **one** repo, org, or enterprise at a
time. Personal accounts cannot have org-level runners at all.

That single constraint is the root cause of the current setup's shape: two
runner installations, two hand-pasted registration tokens that expire in an
hour, and a repo URL hardcoded into `scripts/github-runner.sh`. Every one of
those is a symptom, not a problem in itself.

Both repos currently live under the personal account `mchellmer`.

## Decision

Create a free `nineteenseventytwo` GitHub organisation and move
`nineteenseventytwo-eightbitsaxlounge`, `nineteenseventytwo-composer` and this
repo into it.

## Consequences

- **Org-level runners serve every repo in the org.** "A runner for whichever
  repo is queueing" stops being a thing anyone has to think about.
- One GitHub App, installed once on the org, replaces token pasting entirely.
  The runner container mints its own registration token at start.
- Org-level Actions secrets: `SOPS_AGE_KEY` and friends are configured once
  rather than per repo.
- Runner groups become available, so a scale set can be restricted to specific
  repos later without changing the registration model.
- ARC (`gha-runner-scale-set`) is org-scoped, which is the design assumed
  throughout `cluster/arc/`.
- **Cost:** repo URLs change. Every clone remote, every CI reference, the GHCR
  image paths (`ghcr.io/nineteenseventytwo/...`), and the Argo CD `repoURL`
  need updating. GitHub redirects the old URLs, but relying on redirects for
  infrastructure is how a rename becomes an outage six months later.
- Transferring a repo transfers its Actions secrets but **not** its runners;
  they must be re-registered. That is a one-time cost paid to never do it again.

## Alternatives considered

**Stay on the personal account.** Rejected: it makes org-level runners
impossible, which means the token-pasting problem is structural rather than
incidental. Everything downstream — one App, org secrets, runner groups, ARC —
depends on this decision.

**Enterprise account.** Rejected: costs money and solves a problem (multiple
orgs) that does not exist here.
