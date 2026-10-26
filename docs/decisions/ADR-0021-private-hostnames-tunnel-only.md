# ADR-0021: Private hostnames reach their Service through the tunnel only, not the Gateway

**Status:** Accepted
**Date:** 2026-10-26

## Context

[ADR-0018](ADR-0018-personal-website.md) puts the private half of the site,
`dash.eightbitsaxlounge.com`, behind Cloudflare Access, reached through a
Cloudflare Tunnel into the cluster. 07's Phase 8 left three things open:

- **8.1:** "a scoped allow to the Gateway only". The tunnel should not be able
  to reach everything.
- **8.2:** "confirm the Access JWT is actually validated, not merely present.
  The origin must be unreachable except through the tunnel."
- **8.2:** "decide and record whether internal Unbound overrides keep bypassing
  Access from VLAN 20".

The 8.1 wording and the 8.2 requirement pull against each other. The shared
Gateway ([ADR-0015](ADR-0015-cilium-gateway-api.md)) is a LoadBalancer on
`192.168.20.241`, so anything on VLAN 20 can reach it. Suppose `dash.` were a
Gateway listener with an HTTPRoute. Then a LAN client with an Unbound override,
or just a `Host:` header, reaches the origin without Access, and Access becomes
decoration for anyone inside the house.

The Gateway's data plane is also Cilium's Envoy (the reserved `ingress`
identity), not a pod. "cloudflared may reach only the Gateway" would therefore
have to be a CIDR rule to the VIP, which then reaches every hostname the
Gateway serves.

## Decision

**A private hostname has no Gateway listener, no HTTPRoute and no Unbound
override. cloudflared forwards straight to that hostname's ClusterIP Service.**

1. **cloudflared validates the Access JWT.** Every tunnel ingress rule sets
   `originRequest.access: {required: true, teamName, audTag}`. A request
   without a valid token for that application's AUD is rejected at the
   connector and never reaches the origin.
2. **The origin admits only cloudflared.** The NetworkPolicy on `dash` allows
   ingress from `app.kubernetes.io/name: cloudflared` pods in the `cloudflared`
   namespace on 8080, and nothing else.
3. **cloudflared reaches only its origins.** Its egress is DNS, the internet on
   7844 (edge) and 443 (Access signing keys), and the `dash` pods on 8080. It
   has no ingress rule at all.
4. **The ingress rules are in git.** The tunnel is locally managed: its config
   is templated in `cluster/cloudflared/00-externalsecret.yaml`, and only the
   IDs and the credential come from Vault. Adding a hostname is a reviewed PR,
   not a dashboard click.

**The 8.2 question, answered:** there are no Unbound overrides for private
hostnames, and the tunnel is the only path, including from VLAN 20. Inside the
house you go through Access like everyone else.

## Consequences

- **Access cannot be bypassed from the LAN.** No address on VLAN 20 serves
  `dash.`, and the pod's NetworkPolicy refuses anything that is not cloudflared.
- **The app does not validate the JWT itself.** Doing so would mean egress from
  `dash` to Cloudflare for signing keys. It trusts the two controls in front of
  it instead: cloudflared's `access.required` check and the ingress rule. If a
  second path to the origin is ever added, app-side validation is required
  before it merges.
- **Private traffic is plain HTTP inside the cluster**, from cloudflared to the
  pod. TLS ends at Cloudflare's edge and the tunnel itself is encrypted, so the
  only clear-text hop is pod-to-pod.
- **A private hostname cannot use the Gateway's certificates or Cilium L7
  features.** Neither is needed: Cloudflare terminates TLS for the hostname.
- **Each new private hostname needs four changes:** a tunnel ingress rule, an
  egress rule on cloudflared, an ingress rule on the origin, and an Access
  application (or a domain added to an existing one). That is deliberate
  friction.
- **When the cluster is down, Cloudflare serves its own tunnel error.** That
  is the signal (09 F8). The public site is unaffected (ADR-0018).
- **Grafana and Argo CD stay on the Gateway for now.** Moving them behind
  Access (09 "Still open") means making them tunnel-only on the same terms,
  which removes their LAN listeners. That is a separate decision.

## Alternatives considered

- **Tunnel to the Gateway, as 8.1 is worded.** Rejected. It leaves the origin
  reachable from VLAN 20 around Access, and expressing "the Gateway only" in
  policy means a VIP CIDR rule that reaches every hostname the Gateway serves.
- **Tunnel to the Gateway, plus app-side JWT validation.** That closes the
  bypass, but every private app has to implement it correctly, and each one
  needs internet egress for Cloudflare's keys. Rejected in favour of one check
  at the connector.
- **Remotely managed tunnel** (ingress configured in the Cloudflare dashboard,
  `--token` only). Simpler to start, but what the tunnel can reach would live
  outside git. Rejected for the same reason the rest of this repo is GitOps.
