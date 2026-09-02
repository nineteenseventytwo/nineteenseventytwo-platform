# ADR-0015: Cilium Gateway API replaces ingress-nginx

**Status:** Accepted
**Date:** 2026-09-02

## Context

`kubernetes/ingress-nginx` was officially retired and its repository archived
to read-only on 2026-03-24 — no more features, no more bug fixes, and
critically, no more CVE patches, ever. The retirement was driven by repeated
security incidents, including CVE-2025-1974 ("IngressNightmare", a critical
unauthenticated RCE via exposed admission webhooks) and four more HIGH-severity
CVEs disclosed in February 2026. The underlying Kubernetes `Ingress` API is not
being removed and remains generally available, but it is feature-frozen —
active development has moved to Gateway API.

This surfaced during a general security review ahead of onboarding real tenant
workloads: a scheduled image-vulnerability scan (`image-vuln-scan.yml`) and a
CVE-currency pass across every chart in the cluster. Running an
internet-facing ingress controller that will never receive another security
patch is the wrong thing to still be doing at that point, not something to
defer until it causes an incident.

Three of ingress-nginx's consumers existed at the time of this decision — Argo
CD, Grafana (kube-prometheus-stack), and Vault — each a single hostname, TLS
via cert-manager, no path routing, no rewrites, no exotic nginx annotations.
No hand-authored `Ingress` resource existed anywhere in the repo; every one
went through a Helm chart's own `ingress:` values block.

## Decision

**Cilium Gateway API, not a standalone Gateway API implementation.**

Cilium is already this cluster's CNI (ADR-0003) and already runs the
`cilium-envoy` DaemonSet its Gateway API support depends on for L7 proxying —
enabling `gatewayAPI.enabled: true` adds zero new components, zero new pods,
and zero new images to scan. All three ingress-nginx consumers' own Helm
charts already ship native `httproute:` support, so no hand-written proxy
configuration was needed either.

Enabling it required a real prerequisite, not just a values.yaml flag:
Cilium's Gateway API controller refuses to start its `GatewayClass`
reconciler without `kubeProxyReplacement` enabled (confirmed live — the
operator logged `"Gateway API support requires kube-proxy-replacement
enabled"` and the `GatewayClass` sat in `Unknown`/"Waiting for controller"
indefinitely otherwise). This cluster had deliberately shipped in standard
mode (`cilium_kube_proxy_replacement: false`) — `docs/03-cluster.md` already
anticipated flipping it later as "a supported migration." That migration
happened as part of this same effort: `kube-proxy` removed from all three
nodes, Cilium's eBPF replacement enabled in its place. This is not a
regression in what Cilium already did for pod networking (eBPF routing,
NetworkPolicy, WireGuard encryption) — it completes it. The prior hybrid
(eBPF for pod-to-pod, iptables for kube-proxy's Service routing) was the less
pure form; a from-scratch Cilium install typically skips kube-proxy from the
start.

One shared `Gateway` (`cluster/gateway/`), not one Gateway per app — mirrors
the topology ingress-nginx already had (one controller, one LoadBalancer IP,
every app attaching to it), keeping the OPNsense DNS override model unchanged
rather than needing one override per app.

## Consequences

- **The LoadBalancer IP changed** (`192.168.20.240` → `192.168.20.241`) — a
  new Service, not a reused one, since both had to run in parallel during the
  cutover. Pinned via `spec.infrastructure.annotations`'
  `metallb.io/loadBalancerIPs` on the Gateway resource, the Gateway-API
  equivalent of ingress-nginx's own `controller.service.loadBalancerIP`
  (Cilium's own `spec.addresses` field needs LB-IPAM, which this cluster
  doesn't use — MetalLB does the actual allocation).
- **Cilium's Gateway data plane identifies itself as a reserved `ingress`
  entity**, not a matchable pod (`cilium-envoy` runs `hostNetwork: true`).
  Only `CiliumNetworkPolicy`'s `fromEntities: [ingress]` can match it — a
  plain Kubernetes `NetworkPolicy` podSelector, the first thing tried, matched
  nothing and cost a full round of live debugging (root-caused with
  `hubble observe`, not guessed) before the working pattern was known. Every
  app's default-deny NetworkPolicy needed this reserved-entity rule added
  alongside its HTTPRoute cutover.
- **Argo CD bootstraps itself** (`make bootstrap-argocd`, a one-shot `helm
  upgrade --install`, not a GitOps Application) and so is the one consumer
  whose cutover a `git merge` alone doesn't apply — it needs that command
  re-run by hand afterward, same as any other Argo CD chart change.
- **CI's Vault AppRole (`ci-ssh-signer`) survived unchanged.**
  `secret_id_bound_cidrs` was already scoped to the cluster's pod network
  (`10.244.0.0/16`), not console's own address, because ingress-nginx's own
  reverse-proxy hop already replaced the real source address before vault-0
  ever saw it. Re-verified live via `hubble observe` after the cutover: the
  TCP-layer peer address Cilium's Gateway data plane presents to vault-0 is
  also a `10.244.0.0/16` address — same pod-network range, no Vault-side
  change needed.
- **Argo CD itself has a recurring gotcha with Gateway API resources**:
  `Gateway` and `HTTPRoute` carry enough server-populated status
  (addresses, per-listener/per-parent conditions) that Argo CD's default
  client-side diff perpetually flags them `OutOfSync` even when sync
  succeeds and the live object is correct. Every Application that owns one
  needed `argocd.argoproj.io/compare-options: ServerSideDiff=true` added.
  Hit and fixed four times before it stopped being a surprise
  (`gateway-api-crds`, `gateway`, `monitoring`, pre-emptively `vault`).
- **kube-proxy's removal is a hard cutover**, not a gradual one — kube-proxy
  and Cilium's eBPF replacement track Service routing independently
  (separate conntrack/NAT state), so there's a brief window with no Service
  routing at all between removing one and the other coming up. Sequenced
  deliberately: remove kube-proxy, merge the `kubeProxyReplacement: true`
  values change, force-sync Cilium immediately — not spread across days.

## Alternatives considered

**A standalone Gateway API implementation (e.g. Envoy Gateway).** Would have
worked without touching `kubeProxyReplacement` at all. Rejected because it
adds an entire new component with its own upgrade cadence, its own images to
scan, and its own operational surface, to solve a problem Cilium — already
running, already scanned, already patched on the same cadence as everything
else — already solves once `kubeProxyReplacement` is on. The kube-proxy
migration was going to be worth doing on its own merits eventually anyway
(`docs/03-cluster.md` had flagged it as a deferred, supported migration since
the cluster was first built); this just made "eventually" concrete.

**A different Ingress controller, staying on the Ingress API (e.g.
Traefik).** Rejected: re-lands on the exact API surface the ecosystem is
actively moving away from, trading one controller's eventual retirement risk
for a different one's, without gaining Gateway API's actual benefits (portable
routing config, native multi-listener/multi-protocol support, no
implementation-specific annotation dialect).

**Do nothing; accept ingress-nginx's unpatched risk short-term.** Rejected
given the timing — onboarding real tenant workloads onto a permanently-
unpatched internet-facing component is the wrong order of operations, and
nothing about the actual migration turned out to require waiting for a
better moment.
