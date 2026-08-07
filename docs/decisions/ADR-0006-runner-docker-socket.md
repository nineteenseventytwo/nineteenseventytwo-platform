# ADR-0006: Mount the docker socket in the bootstrap runners

**Status:** Accepted, with a stated exit
**Date:** 2026-08-07

## Context

The interim runner topology is docker-compose on `1972-console`, before the
cluster exists. Those runner containers need to start sibling containers — the
whole `workflow → containerised Ansible → Pis` pattern depends on it.

The two ways to give a container that ability are mounting the host's docker
socket, or running docker-in-docker.

## Decision

Mount `/var/run/docker.sock` into the compose runners on `1972-console`.

## Consequences

- **Socket mount is approximately root on the host.** A job that can talk to the
  docker socket can start a privileged container with the host filesystem
  mounted. There is no configuration that makes this not true.
- On a machine sitting inside VLAN 20 with SSH keys to every node, that is a
  meaningful exposure. It is accepted because the alternative on a 1 GB RPi 4 is
  dind, which needs a privileged container and more memory than the host has.
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

The compose stack stays on `1972-console` afterwards as the break-glass path —
it is how you rebuild the cluster that hosts ARC. Its exposure persists, which
is why this ADR stays open rather than being superseded.

## Alternatives considered

**dind on console.** Rejected: 1 GB of RAM, and a privileged container is not
obviously better than a socket mount on a host that has neither isolation nor
capacity.

**Rootless docker.** Genuinely better, and worth revisiting. Rejected for now
because it complicates the sibling-container pattern the workflows depend on,
and the cluster path (which removes the problem entirely) arrives sooner.
