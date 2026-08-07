# ADR-0007: `1972-console` stays out of the cluster

**Status:** Accepted
**Date:** 2026-08-07

## Context

Four Pis. Three are RPi 5s with 2 GB. `1972-console` is an RPi 4 with **1 GB**.

The obvious instinct is to use all four — a fourth node is a fourth node.

## Context that makes it not obvious

`1972-console` is what *builds* the cluster. It runs the bootstrap runner that
executes the Ansible that runs `kubeadm init`.

## Decision

`1972-console` is not a cluster node. It is the bootstrap node and the
break-glass runner host.

## Consequences

- **No circular dependency.** If console were in the cluster, rebuilding the
  cluster would require the cluster to be up to run the runner that rebuilds it.
  There is always one machine that can bootstrap everything else from nothing,
  and that is the whole value of it.
- 1 GB will not take a kubelet plus two runner containers plus dockerd. It would
  be the node that OOMs, and it would OOM while running the job that was fixing
  something.
- The compose runner stack survives an entire cluster loss, which is exactly
  when you need a runner.
- **Cost:** one fewer worker. With Longhorn at 2 replicas across 2 workers, the
  cluster tolerates one node down and no more. A third worker would help, and
  this is the reason there isn't one.
- Memory cgroups are not enabled on console (the cloud-init template skips it
  for non-cluster nodes), so it cannot accidentally be joined without noticing.
  `tests/goss/node.yaml` correctly fails that check on console.

## Alternatives considered

**Join console as a worker with a taint.** Rejected: it still runs a kubelet,
which is the memory that isn't there, and it still creates the bootstrap cycle.

**Use console as the control plane and one RPi 5 as a third worker.** Rejected:
etcd on 1 GB with an SD-era RPi 4's I/O is asking for the failure mode where the
control plane is the thing that falls over.
