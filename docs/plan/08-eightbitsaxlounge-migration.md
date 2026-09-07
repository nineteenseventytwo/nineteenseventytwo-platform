# 08 — The eightbitsaxlounge migration

_Written 2026-09-07. The execution plan for [07](07-completion-plan.md)'s
Phase 6.1–6.2, and the thing [05-migration.md](../05-migration.md)'s mapping
table has been waiting for since build 0001._

Verified against `mchellmer/nineteenseventytwo-eightbitsaxlounge` at `7cb24af`
plus its uncommitted GPU work, the live cluster, and the GitHub API.

---

## What is being moved, and what is not

Seven top-level services. The repo does two jobs today — build the image, and
own the Kubernetes manifests. [ADR-0012](../decisions/ADR-0012-platform-owns-app-workloads.md)
splits those: **job 1 stays, job 2 moves here.**

| Service | What it is | Deps | Manifests | Verdict |
|---|---|---|---|---|
| `db` | CouchDB | none | deployment, svc, PVC, ingress | → `apps/` |
| `state` | NATS JetStream, StatefulSet, 1 replica, 1Gi Longhorn | none | statefulset, 2 svc, secret | → `apps/` |
| `data` | Go CRUD API over CouchDB | `db` | deployment, svc, ingress | → `apps/` |
| `midi` | .NET API, cluster half of the MIDI split | NATS, **Windows PC** | deployment, svc, cm, secret | → `apps/` + host work |
| `overlay` | Node/socket.io OBS overlay | NATS | deployment, svc, secret, ingress | → `apps/` |
| `chat` | Python TwitchIO bot | NATS, `midi` | deployment, cm, secret, PVC | → `apps/` |
| `security` | Trivy CronJob, uploads SARIF with a **PAT** | — | cronjob, PVC | **delete** |
| `monitoring` | Ansible + Alloy → Grafana **Cloud** | — | — | **delete** |
| `server` | The old platform layer | — | — | **delete**, after the table closes |

---

## Findings — settle these before service 1

Nine things the migration trips over. Several are cheap; two are ordering
constraints; one is a prerequisite nobody wrote down.

### F1 — The repo is not in the organisation

`git remote` says **`mchellmer/nineteenseventytwo-eightbitsaxlounge`**, public.
`platform` and `cloud` are both under `nineteenseventytwo/`.
[ADR-0001](../decisions/ADR-0001-github-org.md) established the org and
05-migration's week 1 said "move repos" — this one never moved.

It is a prerequisite, not a tidy-up. The tenant CI credential, the GHCR
namespace the `image:` fields will point at
(`ghcr.io/nineteenseventytwo/…` vs `ghcr.io/mchellmer/…`), the org-scoped
runner, and the org secrets all assume the org. Migrating first and moving
after means repointing every `image:` twice.

**Do this first.** GitHub redirects the old URL, so nothing breaks on the way.

### F2 — Every Ingress targets an ingress controller that no longer exists

All three `ingress.yaml.j2` files say `ingressClassName: nginx`.
[ADR-0015](../decisions/ADR-0015-cilium-gateway-api.md) replaced ingress-nginx
with **Cilium Gateway API**. Nothing in `cluster/` installs an ingress
controller any more, so these would be admitted and then silently ignored.

05-migration's mapping table still routes `k8s-ingress-nginx.yaml` to
`cluster/ingress-nginx/`. That row is stale and should be corrected as part of
this work.

Each externally-reachable service instead needs:

1. an **`HTTPRoute`** in `apps/eightbitsaxlounge/<env>/`, attaching by hostname
2. a **listener** on the shared Gateway in `cluster/gateway/00-gateway.yaml`,
   with its own `hostname` and `certificateRefs`
3. a **`Certificate`** issued by the `letsencrypt-prod` ClusterIssuer
4. an **Unbound override** on OPNsense pointing the name at `192.168.20.241`

### F3 — This is also the answer to "should everything be HTTPS?"

Yes and no, and the distinction is the point.

**North–south (browser → service): yes, and it is nearly free.** The Gateway
terminates TLS per hostname. The app keeps listening on plain HTTP inside the
pod; it does not need a certificate, and `ASPNETCORE_URLS=http://+:8080` stays
exactly as it is. "Move to HTTPS" here means "attach an HTTPRoute", not "add
TLS to six services".

**East–west (`data` → `db`, `chat` → NATS): no, deliberately.** In-cluster
service-to-service stays plain HTTP, and the control that makes that safe is
the NetworkPolicy allow-pair, not transport encryption.
[ADR-0003](../decisions/ADR-0003-cni-cilium-no-mesh.md) declined a service mesh
with reasons; mTLS between pods is what a mesh would buy, and that decision has
not changed. Worth stating explicitly in the migration record so it reads as a
choice rather than an omission.

The one genuine exception is **`midi` → the Windows PC**, which leaves the
cluster. See F9.

### F4 — The documented migration order omits a service

[07](07-completion-plan.md) and 05's WP-5 both say:
`db-couchdb → state-nats → chat → midi-api → security → overlay`.

That list has six entries for seven services — **`data` is missing** — and it
puts `chat` third, before the `midi` service `chat` depends on
(`MIDI_CLIENT_ID`, `MIDI_CLIENT_SECRET`, `MIDI_DEVICE_URL`). Corrected order,
derived from the manifests:

```
db  →  state  →  data  →  midi  →  overlay  →  chat
```

`security` is deleted rather than migrated, which is why it looked like six.

### F5 — The quota fits at 92%, which is not a fit

Tenant `dev` allows `requests.cpu: 1`, `requests.memory: 768Mi`,
`limits.memory: 1536Mi`. Summing the six services — with `db` and `data`
picking up the namespace LimitRange defaults, since neither declares resources
at all:

| | requests.cpu | requests.memory | limits.memory |
|---|---|---|---|
| Sum of the six | ~350m | ~512Mi | **~1408Mi** |
| `dev` quota | 1 | 768Mi | **1536Mi** |
| Headroom | 65% | 33% | **8%** |

`limits.memory` is the binding constraint, and 8% headroom means the first
service that needs a bump fails admission — which will read as a broken
manifest rather than an exhausted quota. Raise `dev` to `2Gi` **in the same PR
as the first service**, with the reason, exactly as
`policy/tenants/eightbitsaxlounge.yaml` instructs. `prod` at `2Gi` is fine.

PVCs: `chat` (tokens), `db` (couchdb-data), `state` (volumeClaimTemplate) = 3,
against a quota of 4. Deleting `security` is what keeps that under the line.

### F6 — The vulnerability problem is base images, not dependencies

Direct dependencies are in better shape than expected — `python:3.14.3-slim`,
`twitchio 3.2.1`, `go 1.26`, `chi v5.2.5`, `node:25-slim`, `express ^5.2.1`,
.NET 10. Little to do there.

Four services float their base image, which is both a supply-chain problem and
a reproducibility one:

| Service | Base | Problem |
|---|---|---|
| `data` | `alpine:latest` | unpinned |
| `db` | `couchdb:latest` | unpinned |
| `state` | `natsio/nats-box:latest` | unpinned |
| `security` | `ubuntu:22.04` | superseded — deleted anyway |

Pin all three survivors to a digest during the migration. This is what Trivy
and Checkov flag first, and the weekly re-scan
(`image-vuln-scan.yml`) cannot tell you anything useful about a tag that means
something different each week.

### F7 — Git hygiene: the app repo has none of the controls the others have

Checked against the API, 2026-09-07:

| | 8BSL | platform / cloud |
|---|---|---|
| Ruleset on `main` | **none** | `main` — deletion, non-fast-forward, PR required, signed commits |
| Secret scanning | **disabled** | — |
| Push protection | **disabled** | — |
| Dependabot security updates | **disabled** | — |
| Dependabot config | **absent** | — |
| CI on pull requests | **none** — all 15 workflows are `workflow_dispatch`/`push`, and `test.yml` is dispatch-only | lint + Checkov + Trivy on every PR |

Every one of those is free on a public repo, and the repo is public. The
absence of `pull_request` triggers is *why*
[ADR-0010](../decisions/ADR-0010-fork-pr-self-hosted-runners.md) is closed — but
it also means nothing tests a change before it lands.

Note the platform ruleset itself requires **no status checks** and **zero
approvals**. Worth deciding whether that is intentional for a one-person estate
or a gap; either way, mirror the answer onto the app repo rather than leaving
it with nothing.

### F8 — Why Grafana looks empty, and what actually fixes it

`monitoring/` deploys Grafana **Alloy** shipping to Grafana **Cloud**. The
cluster now runs `kube-prometheus-stack` in-cluster. Those are two unrelated
systems, which is why the in-cluster Grafana shows nothing familiar.

The in-cluster Grafana is not misconfigured. It has cluster and node dashboards
and they work. What is missing is **application** metrics — and no 8BSL service
exposes a `/metrics` endpoint or ships a `ServiceMonitor`, so there is nothing
for Prometheus to scrape. Deleting `monitoring/` loses nothing that currently
works.

Making app metrics appear is separable, genuinely useful, and should not block
the migration: instrument one service, add its `ServiceMonitor` to
`apps/eightbitsaxlounge/<env>/`, confirm it appears, then decide whether the
others are worth it. `data` (Go) is the cheapest first candidate.

### F9 — The MIDI split is the only flow that leaves the cluster

The cluster-side `midi` API talks to a Windows service on the PC over
`MIDI_DEVICE_URL`, because a container cannot reach the USB effects pedal. That
is a sound reason and the split should stay.

Three things are stale or unproven:

- **`init-pc.yaml` targets `192.168.68.50`** and installs `dotnet_version:
  9.0`. The PC is now reserved at **`192.168.20.210`** on VLAN 20, and `midi`
  builds against **.NET 10**. Both wrong.
- **The Windows-side deployment is believed to have been failing silently for
  some time**, working only because nothing changed. `midi-pc-deploy.yaml`
  drives NSSM on ports 5000 (dev) / 5001 (prod). **Verify before migrating the
  cluster half** — otherwise a broken cluster-side deploy and a
  pre-existing broken Windows-side deploy are indistinguishable.
- **The path needs explicit permission at two layers now.** Default-deny is in
  force in the tenant namespace, so `midi` needs a NetworkPolicy egress
  allow-pair to `192.168.20.210:5000,5001`; and the PC calling back into the
  cluster needs an OPNsense rule plus, if it is an HTTP call, its own
  HTTPRoute. Under a flat `192.168.68.0/24` LAN neither existed.

This is also the one place F3's "east–west stays HTTP" does not apply: the hop
crosses a host boundary onto a Windows machine. It is still inside VLAN 20, so
TLS there is a judgement call rather than a requirement — but it is the only
link where the question is real.

### F10 — Six `server/` items are not in the mapping table

The table is the deletion gate, so anything missing from it blocks deleting
`server/`. Not in it today:

`shutdown.yaml` · `roles/helm` · `roles/k8s_iptables` · `files/manifests` ·
`k8s/` (empty) · and five scripts — `containerd-reinstall.sh`,
`dhcp-restart.sh`, `dockerSource.sh`, `gitlabs-runner.sh`,
`kubernetes-checkcert.sh`.

Two were checked and **are** genuinely covered here, so they only need a table
row: Longhorn's `open-iscsi`/`nfs-common` prerequisites are in
`ansible/roles/kube_prereqs/defaults/main.yml`, and helm installation is in
`ansible/roles/kube_control_plane`.

**`shutdown.yaml` is the one with no replacement.** It shuts down workers,
waits 30s, then the control plane — an ordered shutdown, driven by the
`server-shutdown.yaml` workflow. Nothing in this repo does that, and
`docs/07-runbooks.md` covers what an *unclean* reboot leaves behind, which is
the failure this playbook exists to avoid. Decide: port it to
`ansible/playbooks/`, or accept pulling power and lean on the runbook.

---

## Sequence

### Phase 6.1a — Prerequisites _(~6h)_

- [ ] **F1** — transfer the repo to `nineteenseventytwo`
- [ ] **F7** — ruleset on `main`; enable secret scanning, push protection and
      Dependabot; add `.github/dependabot.yml`
- [ ] Add a PR CI workflow: lint + test + Checkov + Trivy fs, on
      `pull_request`, **hosted runners only** — self-hosted on a `pull_request`
      trigger is what ADR-0010 exists to prevent, and a public repo makes it a
      live path into VLAN 20
- [ ] **F5** — raise the `dev` tenant `limits.memory` to `2Gi`
- [ ] **F9** — verify the Windows-side MIDI service is actually running before
      anything else moves; fix `init-pc.yaml`'s address and .NET version
- [ ] **F6** — pin `data`, `db` and `state` base images to digests

**Gate:** the repo is in the org, a PR runs CI on a hosted runner, and the
Windows MIDI service is confirmed working or confirmed broken — but known.

### Phase 6.1b — Services, one at a time _(~24h)_

Order per **F4**: `db → state → data → midi → overlay → chat`.

Per service, in one PR:

1. Manifests into `apps/eightbitsaxlounge/dev/`
2. `image:` repointed at `ghcr.io/nineteenseventytwo/…`
3. Resource requests sized to fit the quota
4. Every `Secret` → an `ExternalSecret` against `kv/tenants/eightbitsaxlounge/*`
5. Its NetworkPolicy allow-pair — default-deny is already in force, so a
   service that works *without* one has a policy that is wrong
6. For anything externally reachable: `HTTPRoute` + Gateway listener +
   `Certificate` + Unbound override (**F2**)
7. Verify `Synced/Healthy`, then the service actually works, **then** the next

Promote to `prod/` once `dev` holds.

**Gate:** all six `Synced/Healthy` in both environments, and the end-to-end
path works — a Twitch message changing an effect, the pedal responding, the
overlay updating, state persisting.

### Phase 6.2 — Retire the old layer _(~10h)_

- [ ] Repoint the 15 `runs-on: self-hosted` workflows: build/release → hosted
      or the ARC scale set; the runtime-operation ones
      (`chat-set-environment`, `midi-data-*`, `midi-request-*`) stay in the app
      repo but need a runner that exists
- [ ] **F10** — add the six missing rows to the mapping table; decide
      `shutdown.yaml`
- [ ] Delete `security/` and `monitoring/`
- [ ] Replace `server/README.md` with a stub, work the table to zero, delete
      `server/`
- [ ] Correct 05-migration's stale `ingress-nginx` row (**F2**)

**Gate:** the mapping table has no open rows; `server/` is gone; no workflow
targets the retired runner.

### Follow-on, deliberately not blocking

- **F8** — instrument `data`, add a `ServiceMonitor`, confirm it appears in
  Grafana, then decide about the rest
- `chat-set-environment.yaml` rewritten to restart by deleting the Pod rather
  than scaling the Deployment — carried from build 0003
- Tailscale/WireGuard: **not now.** It belongs with
  [07's Phase 9](07-completion-plan.md#phase-9--hybrid) and its OPNsense
  blocker, not in an app migration

---

## Open decisions

| | Question | Recommendation |
|---|---|---|
| **M1** | Port `shutdown.yaml` or drop it? | **Port it.** It is ~20 lines, it is the only graceful-shutdown path, and the alternative is pulling power on Longhorn replicas. |
| **M2** | Required status checks and approvals on `main`, across all three repos? | **Require checks, keep approvals at 0.** Checks catch what a one-person estate cannot self-review; a mandatory approval on a solo repo is theatre that gets bypassed. |
| **M3** | TLS on `midi` → Windows PC? | **Not initially.** It stays inside VLAN 20 with an explicit allow-pair at both layers. Revisit if the PC ever leaves VLAN 20 — record it as accepted, not overlooked. |
| **M4** | `dev` and `prod`, or `prod` only? | **Keep both.** The quota already provisions both, and dev is where the HTTPRoute and ExternalSecret wiring gets proven before prod. |
