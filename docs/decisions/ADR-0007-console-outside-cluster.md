# ADR-0007: `1972-console-1` stays out of the cluster

**Status:** Accepted
**Date:** 2026-08-07
**Amended:** 2026-08-07 — console's hardware changed from an RPi 4/1 GB to an
RPi 5/2 GB/SSD, matching the three cluster nodes exactly. The decision is
unchanged; the reasoning underneath it is not the same reasoning anymore, and
pretending otherwise would leave a false claim on record. See the note inline
below wherever this bites.

## Context

Four Pis, all RPi 5s with 2 GB and an SSD. Hardware-wise, there is nothing left
that distinguishes `1972-console-1` from `1972-master-1`, `1972-worker-1`, or
`1972-worker-2`.

That makes the obvious instinct stronger than it used to be: four identical
boards, why not run four identical nodes.

## Context that makes it not obvious

`1972-console-1` is what *builds* the cluster. It runs the bootstrap runner that
executes the Ansible that runs `kubeadm init`. That fact does not depend on
what CPU or how much RAM the board has — it is true for any machine playing
that role, on any hardware.

## Decision

`1972-console-1` is not a cluster node. It is the bootstrap node and the
break-glass runner host.

## Consequences

- **No circular dependency.** If console were in the cluster, rebuilding the
  cluster would require the cluster to be up to run the runner that rebuilds
  it. There is always one machine that can bootstrap everything else from
  nothing, and that is the whole value of it. **This is now the entire
  argument** — see the amendment below.
- The compose runner stack survives an entire cluster loss, which is exactly
  when you need a runner.
- **Cost:** one fewer worker. With Longhorn at 2 replicas across 2 workers, the
  cluster tolerates one node down and no more. A third worker would help, and
  this is the reason there isn't one.
- Memory cgroups are not enabled on console (the cloud-init template skips it
  for non-cluster nodes), so it cannot accidentally be joined without
  noticing. `tests/goss/node.yaml` correctly fails that check on console. This
  point is unrelated to RAM and unaffected by the hardware change.

> **Amendment:** the original version of this ADR leaned heavily on "1 GB will
> not take a kubelet plus a runner" as a second, independent reason console
> stays out. With console now at 2 GB — identical to the other three boards —
> that argument is gone. A kubelet would fit resource-wise. **The reason console
> stays out is now purely architectural: the circular bootstrap dependency
> above, on its own, is sufficient and was always the stronger argument.** If
> that argument did not exist, there would be no remaining reason not to make
> console a fourth worker.

## Alternatives considered

**Join console as a worker with a taint.** Rejected: it still creates the
bootstrap cycle — a rebuild of the cluster would need the cluster (or at least
this node's kubelet) already running to run the runner that rebuilds it. The
original rejection also cited "it still runs a kubelet, which is the memory
that isn't there" — no longer true at 2 GB, and no longer part of the
argument. The cycle is reason enough on its own.

**Use console as the control plane, and add a fourth RPi 5 as a third worker.**
Was rejected on I/O grounds — an SD-era RPi 4's storage under etcd's write
pattern. Console now has an SSD like every other node, so that specific
objection no longer applies, and this alternative deserves an honest second
look rather than the same paragraph restated.

It is still rejected, but for the sharper reason underneath the old one:
collapsing "the machine that rebuilds the cluster" and "the machine the
cluster depends on for its control plane" into the same physical box means a
control-plane failure removes your ability to rebuild using that same
machine, at exactly the moment you need to. Keeping them separate is what
makes "break-glass" mean something — the bootstrapper has to be able to
survive a cluster-wide failure, including a control-plane failure, and that
requires it not *be* the control plane.

This alternative would be worth revisiting if a fifth board ever joins the
fleet — at that point "console as control plane, two dedicated workers, one
spare" stops trading away the break-glass property.
