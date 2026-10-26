# ADR-0020: Composer runs in the cluster; its inference runs on the GPU host outside it

**Status:** Accepted
**Date:** 2026-09-07 (decided as 07's D1; built 2026-09-17 to 2026-09-24; recorded 2026-10-26)

## Context

composer turns a piano score into an arrangement, and the model-driven arranger
(`COMPOSER_ARRANGER=plan`) needs an LLM. The only GPU in the estate is an RTX
4060 in an x86 PC. That PC dual-boots: Windows serves eightbitsaxlounge's MIDI
device service, and Linux serves inference.

[ADR-0011](ADR-0011-arm64-only.md) keeps the cluster arm64-only. It says
populating the `gpu` inventory group needs a new ADR, not a config edit. That
group was populated on 2026-09-17 (`1972-gpu-1`, #176) on the strength of
07-completion-plan's D1, with the reasoning in an inventory comment and no ADR.
This record is the ADR that ADR-0011 asked for.

The four options are in [07 §D1](../plan/07-completion-plan.md#d1--where-composers-inference-runs-blocks-phase-63):

- (a) join the PC as an x86 GPU worker
- (b) API in the cluster, inference off it
- (c) Bedrock
- (d) Tailscale-join the PC

## Decision

**(b).** The composer API runs in `composer-dev` on arm64, from an in-house image
pinned by digest. Inference runs on `1972-gpu-1` (192.168.20.210), the PC booted
into Linux. That host is Ansible-managed and is **not a cluster node**: no
kubelet, no cluster workloads, and the role actively removes any earlier
cluster-join attempt.

The one path between the two is:

- **Cluster side:** the egress rule in `apps/composer/dev/composer-networkpolicy.yaml`,
  `192.168.20.210/32`, TCP 11434 only.
- **Host side** (`ansible/roles/gpu_host`, `make deploy-gpu-host`):
  - Ollama is bound to loopback.
  - A Caddy proxy on 11434 forwards only `/api/chat`, `/api/generate` and
    `/api/tags`, and answers 404 to everything else, `/api/delete` included.
  - ufw denies inbound by default and admits the proxy port only from the
    cluster nodes' addresses.

`gpu` is a populated inventory group whose host is not a node. **ADR-0011's
arm64-only rule is unchanged.**

## Consequences

- **composer shipped without reopening ADR-0011.** No multi-arch builds, no
  NVIDIA device plugin, no GPU taints, and no node that disappears from the
  cluster whenever Windows is booted.
- **Inference is available only while the PC is in Linux.** When it is in
  Windows, `plan` requests fail at the model call. That is accepted: the two
  uses happen at different times. The deterministic arranger needs no model, so
  setting `COMPOSER_ARRANGER=deterministic` in the ConfigMap is the fallback,
  not a redeploy.
- **The NetworkPolicy and the host firewall are the only controls on this
  path.** The nodes and the GPU host share VLAN 20, so the traffic is
  switch-local and OPNsense never sees it. That is why both ends name a single
  address and a single port.
- **The inference call is plain HTTP, authenticated by source address only.**
  That is acceptable for a same-VLAN path carrying scores and prompts. It is
  not acceptable if the host ever moves off VLAN 20, which is (d)'s trigger.
  TLS on this hop would follow the pattern the MIDI path adopted in 08's M3.
- **`site.yml` does not touch the GPU host.** `40-gpu-host.yml` is a separate,
  deliberate run, because a whole-estate converge must not fail when the PC
  happens to be booted into Windows. The cost is that it can drift. Re-run it
  after any change to the role.
- **dev only.** `policy/tenants/composer.yaml` creates no prod namespace,
  because nothing depends on composer yet. Add prod when something does.

## Alternatives considered

- **(a) Join the PC as an x86 GPU worker.** Rejected. Every image the cluster
  runs would need multi-arch builds forever, plus the device plugin, a runtime
  class and taints, all for a node that is absent whenever Windows is booted.
  ADR-0011's point 6 still holds.
- **(c) Bedrock.** Not rejected, deferred. The plan is a second backend behind
  the same LLM client interface, using an IRSA role for the composer pod (the
  pattern already exists, [ADR-0014](ADR-0014-pod-identity-webhook.md)). The
  pair then becomes the local-vs-managed comparison the 90-day plan asked for.
  Revisit in 07's Phase 11. `DenyExpensiveResources` does not block Bedrock
  (09 F3).
- **(d) Tailscale-join the GPU host.** Not needed while both ends are on
  VLAN 20. Revisit if the PC moves off it, together with TLS on the hop.
