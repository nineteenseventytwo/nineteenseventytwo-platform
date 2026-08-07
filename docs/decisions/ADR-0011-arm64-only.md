# ADR-0011: arm64 only; the x86 GPU node is out of scope for now

**Status:** Accepted
**Date:** 2026-08-07

## Context

There is an x86 PC in the lab that dual-boots Windows (for the
`eightbitsaxlounge` midi-api) and Linux. Its Linux side has a GPU and is
currently set up as a node for the `nineteenseventytwo-composer` training
workloads, outside any cluster.

It is the only x86 machine and the only GPU. Joining it to the cluster changes
several assumptions at once.

## Decision

The cluster is **arm64 only**. The `gpu` inventory group exists and is
deliberately empty.

## Consequences

- Image builds are single-arch on `ubuntu-24.04-arm`. Native, fast, no QEMU.
- No `nodeSelector`/`nodeAffinity` on architecture anywhere, no taints and
  tolerations for GPU scheduling, no NVIDIA device plugin to run and debug.
- The composer training workload keeps its current out-of-cluster setup, which
  works today.
- **The day this changes, multi-arch builds become mandatory** — every image
  the cluster runs must exist for both architectures, or pods will schedule
  onto a node that cannot run them and fail with an exec-format error that does
  not mention architecture.
- The empty `gpu` group in the inventory is the marker. Populating it is a
  deliberate decision requiring a new ADR, not a config edit.

## What joining it would require

Recorded so the estimate is not re-derived later:

1. A `kube_worker_gpu` role: NVIDIA driver, container toolkit, containerd
   runtime class.
2. NVIDIA device plugin DaemonSet in `cluster/`.
3. `platforms: linux/amd64,linux/arm64` in `build-images.yml`, plus arm64
   emulation or a second hosted runner for the amd64 leg.
4. Architecture `nodeSelector` on every platform component that is not already
   multi-arch.
5. A taint on the GPU node so general workloads do not land on it.
6. The dual-boot situation means the node is *absent* whenever the PC is in
   Windows — which is a node that regularly disappears, and Longhorn and the
   scheduler both have opinions about that.

Point 6 is the one that most argues for keeping it out.

## Alternatives considered

**Join it now.** Rejected: multi-arch complexity for one node that is offline
whenever someone boots Windows.

**Scaffold the role but disable it.** Rejected as worse than an empty group —
disabled code rots and gives false confidence that it would work if enabled.
