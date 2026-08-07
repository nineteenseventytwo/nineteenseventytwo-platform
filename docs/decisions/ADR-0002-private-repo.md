# ADR-0002: The platform repo is private

**Status:** Accepted
**Date:** 2026-08-07

## Context

This repo contains the network topology, host addresses, MAC addresses,
firewall assumptions, and the structure (though not the values) of every secret
in the lab. It is also the repo whose CI has the most direct path to machines
inside VLAN 20.

Self-hosted runners attached to a public repository are a documented remote
code execution path: a fork pull request can execute arbitrary code on a machine
inside the lab network.

## Decision

`nineteenseventytwo-platform` is **private**.

## Consequences

- The fork-PR RCE path does not exist here at all, rather than being mitigated.
- Hosted `ubuntu-24.04-arm` runners are available in private repos (2 vCPU
  rather than the 4 public repos get) and count against normal free minutes.
  The build jobs are small; this is not a real constraint.
- **Argo CD needs credentials to read the repo.** `cluster/argocd/bootstrap/`
  carries a GitHub App repository credential for exactly this reason — a public
  repo would not have needed one.
- The showcase value is lost for this repo specifically. The mitigation is that
  `eightbitsaxlounge` stays public (see
  [ADR-0010](ADR-0010-fork-pr-self-hosted-runners.md)) and the interesting
  artefacts here — the ADRs, the secret inventory, the Kubescape baseline — can
  be excerpted deliberately rather than exposed wholesale.

## Alternatives considered

**Public with `pull_request` routed to hosted runners.** That is the right
answer for an application repo, and it is what ADR-0010 decides for
`eightbitsaxlounge`. It is the wrong answer here because the repo's *contents*
are a network map, not because of the runner path.
