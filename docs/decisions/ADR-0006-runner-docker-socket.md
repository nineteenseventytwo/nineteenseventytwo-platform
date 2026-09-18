# ADR-0006: Mount the docker socket in the bootstrap runners

**Status:** Accepted, with a stated exit
**Date:** 2026-08-07

## Context

The interim runner topology is docker-compose on `1972-console-1`, before the
cluster exists. Those runner containers need to start sibling containers — the
whole `workflow → containerised Ansible → Pis` pattern depends on it.

The two ways to give a container that ability are mounting the host's docker
socket, or running docker-in-docker.

## Decision

Mount `/var/run/docker.sock` into the compose runners on `1972-console-1`.

## Consequences

- **Socket mount is approximately root on the host.** A job that can talk to the
  docker socket can start a privileged container with the host filesystem
  mounted. There is no configuration that makes this not true.
- On a machine sitting inside VLAN 20 with SSH keys to every node, that is a
  meaningful exposure. It is accepted because the alternative is dind, which
  needs a privileged container — still true on the current 2 GB RPi 5 board;
  see the amendment below for what changed and what did not.
- Mitigations actually applied:
  - A dedicated unprivileged `github-runner` user owns the runner directories,
    so a compromised job sees less on disk.
  - Runners are `--ephemeral`: one job, then the container is replaced, so
    nothing persists for the next job to pick up.
  - The repo is private ([ADR-0002](ADR-0002-private-repo.md)), so there is no
    fork-PR path to this runner at all.
  - Memory limits, so a runaway job fails rather than taking the host down.
- Honest accounting: the unprivileged user narrows what a compromised job *sees*.
  It does not narrow what it can *do* through the socket.

## The exit

Once the cluster is stable, jobs move to ARC scale sets:

- `lab-deploy` uses `containerMode: kubernetes` — **no docker socket at all**,
  and it is the scale set almost everything should use.
- `lab-dind` uses `containerMode: dind` for the rare job that must build
  locally. Still privileged, but privileged *in a pod* rather than root on a
  host with SSH keys to the cluster. Scaled to zero.

The compose stack stays on `1972-console-1` afterwards as the break-glass path —
it is how you rebuild the cluster that hosts ARC. Its exposure persists, which
is why this ADR stays open rather than being superseded.

## Alternatives considered

**dind on console.** Rejected. Originally rejected on capacity as much as
isolation — 1 GB of RAM made a privileged dind container a tight fit on top of
Ansible and the runner containers themselves. Console is now a 2 GB board like
the cluster nodes, so capacity is no longer the binding objection (see the
amendment). It is still rejected on isolation: a privileged container is not
obviously better than a socket mount on a host that has no isolation between
tenants anyway — there is exactly one job running at a time, and dind buys
container-boundary isolation for a threat that does not exist here yet. That
changes once ARC's `lab-dind` scale set exists, where jobs share the cluster
with other tenants' workloads — which is why dind is the answer there and not
here.

**Rootless docker.** Genuinely better, and worth revisiting. Rejected for now
because it complicates the sibling-container pattern the workflows depend on,
and the cluster path (which removes the problem entirely) arrives sooner.

> **Amendment (2026-08-07):** console's hardware changed from an RPi 4/1 GB to
> an RPi 5/2 GB/SSD. The capacity argument against dind above is weaker than it
> was; the isolation argument is not, and is now the sole reason dind is
> rejected here specifically. The overall decision (mount the socket, exit via
> ARC) is unchanged.

> **Amendment (2026-09-18):** the exit has started. `image-vuln-scan`'s
> `enumerate` job is the first to move to the `lab-deploy` scale set, chosen
> because it is read-only and ungated — a cheap place to prove the pattern.
>
> Moving it was not a label swap, and the reason is worth recording: every
> self-hosted job in both repos reaches the socket *through the Makefile*,
> whose tool layer is defined as `docker run ansible-runner <tool>` for
> `KUBECTL`, `ANSIBLE` and `HELM` alike. `lab-deploy` has no socket by design,
> and its stock runner image carries none of those tools itself, so neither
> half of the old arrangement survives the move. What works is `RUNNER_LOCAL=1`
> — the Makefile's existing non-container branch — with the tooling image as
> the job's own `container:`. No socket anywhere in the chain, and the make
> targets are untouched.
>
> Also corrected here: the `--ephemeral` mitigation above says "one job, then
> the container is replaced". Until 2026-09-17 that was true only because a
> second job was impossible — `restart: always` restarted the same container,
> whose stale registration then made `config.sh` refuse, so each runner served
> exactly one job and crash-looped. Nothing persisted between jobs, but not for
> the reason claimed. gha-runner 1.2.0 clears that state on start, which makes
> the mitigation true as written rather than by accident.
>
> Still on the compose stack: `deploy-cluster` and `deploy-nodes`, deliberately
> — they are the break-glass path that rebuilds the cluster ARC itself runs in.
> Not yet moved: eightbitsaxlounge's five self-hosted workflows, which need the
> same `container:` treatment and are what actually ends one Pi being a
> single point of failure for the whole org's CI.
