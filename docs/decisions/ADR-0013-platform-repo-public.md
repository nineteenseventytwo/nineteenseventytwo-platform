# ADR-0013: The platform repo goes public

**Status:** Accepted
**Date:** 2026-08-15
**Supersedes:** [ADR-0002](ADR-0002-private-repo.md)

## Context

ADR-0002 kept `nineteenseventytwo-platform` private for two separate reasons:
the repo's *contents* (network topology, host addresses, MAC addresses,
firewall assumptions, secret structure) and the fork-PR RCE path that opens up
the moment a public repo has self-hosted runners attached — the same runners
that, per [ADR-0006](ADR-0006-runner-docker-socket.md), mount the docker
socket and are approximately root on a host with SSH keys to every cluster
node.

The owner's stated preference now: this repo and other org repos are public
or becoming public, for the same showcase reasoning ADR-0010 already accepted
for `eightbitsaxlounge`. That reasoning is being extended here rather than
re-litigated.

## Decision

`nineteenseventytwo-platform` is **public**. It is mitigated the same way
ADR-0010 mitigates `eightbitsaxlounge`: self-hosted labels appear only on jobs
triggered by `push` to `main` or `workflow_dispatch`, never on `pull_request`.

An audit of every workflow in this repo at the time of this decision confirms
the pattern already holds without any workflow changes:

| Workflow | Trigger | `runs-on` |
|---|---|---|
| `lint.yml` | `pull_request`, `push:main` | `ubuntu-24.04` (hosted) |
| `deploy-cluster.yml` | `push:main`, `workflow_dispatch` | `[self-hosted, ...]` |
| `deploy-nodes.yml` | `push:main`, `workflow_dispatch` | `[self-hosted, ...]` |
| `image-*-build.yml` | `push:branches-ignore:[main]` | `ubuntu-24.04-arm` (hosted) |
| `image-*-promote.yml` | `push:main` | `ubuntu-24.04` (hosted) |

No workflow combines `pull_request` with a self-hosted label. Nothing here
needed to change to make the repo safe to open — the ADR-0010 pattern was
already the convention before this decision made it load-bearing.

The org's runner-group settings must also grant this repo access to public
repositories (`Settings → Actions → Runner groups → <group> → Repository
access`), separately from the repo's own visibility.

## Consequences

- **The fork-PR RCE path now exists in principle** (public repo + self-hosted
  runner group access) but is closed by workflow design, not by the repo
  being unreachable. This is a materially weaker guarantee than ADR-0002's
  "the path does not exist here at all" — see the caveat below.
- **This must be enforced per workflow, in every workflow, forever.** Exactly
  ADR-0010's own warning, now applying to this repo too: one
  `runs-on: self-hosted` added to a `pull_request` job — here or in any future
  workflow — reopens a code-execution path into VLAN 20 silently. Any PR
  touching `.github/workflows/` needs this checked explicitly; it is a review
  convention, not something CI enforces on itself.
- **Network topology, host addresses, MAC addresses and firewall assumptions
  are now public.** This was ADR-0002's other, independent reason for
  privacy, and going public does not mitigate it — it accepts it. Secret
  *values* stay protected (sops+age encrypts them at rest, per
  [ADR-0008](ADR-0008-sops-age.md)); secret *structure*, the lab's addressing
  scheme, and every ADR's reasoning are now visible to anyone.
- Belt-and-braces, carried over from ADR-0010 and required here before the
  runner group's public-repo access is enabled:
  - Settings → Actions → General → **Require approval for all external
    contributors**.
  - Branch protection on `main`, so the only trigger path for self-hosted
    jobs (`push:main`) requires a reviewed PR rather than a direct or
    accidental push.
- Argo CD's repo-read credential (`cluster/argocd/bootstrap/`) is unaffected —
  a GitHub App credential works the same way against a public repo, so
  nothing there needs to change or could be simplified away.
- The showcase value ADR-0002 said this repo was giving up is restored: the
  ADRs, the secret inventory shape, and the Kubescape baseline are visible in
  full rather than excerpted.

## Alternatives considered

**Keep ADR-0002's decision.** Strongest mitigation, and still correct if the
showcase value is ever judged not worth the standing review burden above.
Rejected per the owner's explicit preference, consistent with the same
trade-off already accepted for `eightbitsaxlounge` in ADR-0010.

**Split into a public docs/showcase repo and a private operational repo.**
Would let the network map stay private while the ADRs and reasoning go public.
Rejected as the kind of repo-count growth ADR-0012 already argued against for
a one-person team — the content and the operational config are the same
files, and splitting them fights the "everything reviewable in one place"
value ADR-0012 optimized for.
