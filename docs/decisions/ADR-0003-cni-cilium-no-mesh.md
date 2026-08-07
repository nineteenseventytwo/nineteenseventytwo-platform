# ADR-0003: Cilium as CNI; defer the service mesh

**Status:** Accepted
**Date:** 2026-08-07

## Context

The previous cluster ran Flannel, which cannot enforce NetworkPolicy. That is a
real gap: Pi-to-Pi traffic on VLAN 20 is switch-local, so OPNsense never sees
it and no firewall rule can constrain workload-to-workload traffic.

Separately, "should we run Istio?" gets asked as though it were a CNI choice.
It is not:

| Layer | Job | Options |
|---|---|---|
| CNI | Pod IPs, routing, L3/L4 NetworkPolicy | Cilium, Flannel, Calico |
| Service mesh | Workload identity, mTLS, L7 policy, traffic shifting | Istio, Linkerd, Cilium Service Mesh |

Istio ships an "Istio CNI node agent", but it only handles traffic redirection
and still requires a real CNI underneath. The two are complementary.

The cluster is three RPi 5s with 2 GB RAM each, also running Longhorn and
kube-prometheus-stack.

## Decision

**Cilium as the CNI. No service mesh for now.**

VXLAN tunnel routing, WireGuard node-to-node encryption, Hubble relay on, Hubble
UI off, kube-proxy replacement **off** initially.

## Consequences

- NetworkPolicy is enforceable, so `policy/` default-deny is meaningful rather
  than decorative. This is the change that makes the tenant boundary real.
- Transparent node-to-node WireGuard gives encryption in transit **without** a
  mesh.
- Hubble gives flow observability, which is most of what people actually want
  from a mesh in a lab this size.
- VXLAN rather than native routing: slightly more overhead, but it keeps pod
  networking entirely inside the cluster instead of teaching OPNsense to route
  `10.244.0.0/16`.
- kube-proxy replacement is off by default. It requires `k8sServiceHost` /
  `k8sServicePort` in the values (the API server cannot be reached through a
  Service that does not yet exist). The playbook injects both, so turning it on
  is a one-line change — and it is a supported migration either way.
- **Cost:** Cilium is more complex than Flannel. eBPF datapath problems are
  harder to debug than iptables ones, and `cilium-dbg` is a tool you will have
  to learn.

## The trigger to revisit

Adopt a mesh when there is a concrete need for **L7 policy, per-workload mTLS
identity, or traffic shifting**. Not before.

If that fires, **Istio ambient on top of Cilium** is the choice — sidecar mode
is off the table on 2 GB nodes, and ambient has supported arm64 since 1.15,
though `istiod` + `ztunnel` on these nodes is still a squeeze. Linkerd's stable
build situation makes it harder to recommend right now.

**Write this down now so future-you does not lose an evening:** with default-deny
CiliumNetworkPolicies in place, ambient breaks kubelet health probes unless the
SNAT-ed probe source `169.254.7.127/32` is explicitly allowed.

## Alternatives considered

**Calico.** Comparable NetworkPolicy support and arguably simpler. Rejected
because Cilium's WireGuard encryption and Hubble are both things wanted here,
and getting them from one component beats three.

**Stay on Flannel.** Rejected: no NetworkPolicy enforcement means the tenant
isolation model has no teeth.
