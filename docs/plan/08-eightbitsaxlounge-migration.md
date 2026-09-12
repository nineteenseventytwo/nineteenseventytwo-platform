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

- [x] **F1** — transfer the repo to `nineteenseventytwo`
- [x] **F7** — ruleset on `main`; enable secret scanning, push protection and
      Dependabot; add `.github/dependabot.yml` — confirmed active: `deletion`,
      `non_fast_forward`, `pull_request`, `required_signatures`,
      `required_status_checks` naming `test`/`security`/`yaml`
- [x] Add a PR CI workflow: lint + test + Checkov + Trivy fs, on
      `pull_request`, **hosted runners only** — self-hosted on a `pull_request`
      trigger is what ADR-0010 exists to prevent, and a public repo makes it a
      live path into VLAN 20 — `pr.yml`, all jobs `runs-on: ubuntu-latest`
- [x] **F5** — raise the `dev` tenant `limits.memory` to `2Gi` — both `dev`
      and `prod` tenants, per `policy/tenants/eightbitsaxlounge.yaml`'s own
      comment citing this finding by name
- [x] **F9** — verify the Windows-side MIDI service is actually running before
      anything else moves; fix `init-pc.yaml`'s address and .NET version
- [x] **F6** — pin `data`, `db` and `state` base images to digests — every
      `image:` across all six services' manifests, not just these three

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

- [x] Repoint the `runs-on: self-hosted` workflows: build/release → hosted
      (`ubuntu-24.04-arm`); the runtime-operation ones (`chat-set-environment`,
      `midi-data-*`, `midi-request-*`, `deploy-pc`) stay self-hosted —
      confirmed each one genuinely needs the docker.sock sibling-container
      pattern and/or real VLAN 20 reach, which neither of this repo's ARC
      scale sets offers both of at once. Not 15 in the end: `midi-release.yaml`'s
      `deploy-k8s` job was dead weight (superseded by Argo CD) and deleted
      outright rather than repointed
- [x] **F10** — add the six missing rows to the mapping table; decide
      `shutdown.yaml` — decided differently than M1 below: deleted outright,
      replacement deferred, rather than ported here
- [x] Delete `security/` and `monitoring/`
- [x] ~~Replace `server/README.md` with a stub~~, work the table to zero,
      delete `server/` — deleted outright instead of stubbed, once everything
      eightbitsaxlounge needed was confirmed working in both environments
- [x] Correct 05-migration's stale `ingress-nginx` row (**F2**)

**Gate:** the mapping table has no open rows; `server/` is gone; no workflow
targets the retired runner. **Met, 2026-09-12.**

### Follow-on, deliberately not blocking

- **F8** — instrument `data`, add a `ServiceMonitor`, confirm it appears in
  Grafana, then decide about the rest
- `chat-set-environment.yaml` rewritten to restart by deleting the Pod rather
  than scaling the Deployment — carried from build 0003
- Tailscale/WireGuard: **not now.** It belongs with
  [07's Phase 9](07-completion-plan.md#phase-9--hybrid) and its OPNsense
  blocker, not in an app migration

---

## Decisions — settled 2026-09-07

### M1 — Port `shutdown.yaml`. **Yes.**

Becomes `ansible/playbooks/40-shutdown.yml` + `make shutdown`. Extends to the
EC2 worker in [07's Phase 9](07-completion-plan.md#phase-9--hybrid), where it is
worth more — a stopped instance bills only for its EBS volume.

**The wider intent — the cluster is off unless it is needed — has consequences
worth naming now**, because four things in this estate assume it is always up:

| | Effect of an off-by-default cluster |
|---|---|
| Longhorn | The whole reason ordered shutdown matters. Replicas must detach cleanly; pulling power is what `docs/07-runbooks.md` exists to clean up after. |
| cert-manager | Let's Encrypt certs are 90 days, renewed at ~60. A cluster off for a long stretch renews late or not at all, and DNS-01 needs the cluster running. Not fatal, but a month of downtime around a renewal window is. |
| `image-vuln-scan.yml` | Weekly, Mondays 06:00 UTC. Enumerates images **from the live cluster**, so it fails outright if the cluster is off at that moment. |
| Prowler CronJob | Daily 05:00 UTC. Scans AWS, not the cluster — but it *runs* in the cluster, so an off cluster means no posture scan that day. |

Argo CD will also reconcile a backlog on every boot, which is fine but makes
"everything Synced" a slower gate than it looks.

Worth deciding whether the two scheduled scans move to GitHub-hosted runners so
they survive the cluster being down. That is a small change and it decouples
posture reporting from uptime — recommended, but not blocking the migration.

### M2 — Required status checks. **Yes, and the order matters.**

What "expand" means concretely, in three parts:

**1. The app repo has no ruleset at all.** It needs the base one first, matching
what `platform` and `cloud` already enforce on `main`:

- `deletion` — the branch cannot be deleted
- `non_fast_forward` — no force-push over history
- `pull_request` — changes land through a PR, not a direct push
- `required_signatures` — commits must be signed

That last one is not theoretical here: signing is already configured on the
workstation (recent platform commits verify `G`), and neither existing ruleset
has any bypass actor. So mirroring it costs nothing and closes the gap where the
*app* repo is the one that is public.

**2. Then add `required_status_checks`, naming contexts explicitly.** This is
the part `platform` and `cloud` are currently missing — both rulesets require a
PR but require nothing *of* it, so a red PR merges as easily as a green one.
Name the checks: `lint`, `Checkov`, `test`.

**3. Order is load-bearing.** A required check that never reports blocks every
merge permanently, and a repo with no `pull_request` workflows reports nothing.
So: **add the CI workflow first, open one PR, confirm each check reports, then
require it.** Doing it the other way round locks the repo and the fix needs
admin rights to undo.

On approvals staying at **0**: a required check is a machine that cannot be
tired or in a hurry. A required approval on a single-maintainer repo is the same
person clicking a button they already decided to click — it adds a step without
adding a reader. Revisit if anyone else ever commits.

### M3 — TLS on `midi` → the Windows PC. **Revised: yes, do it.**

The earlier recommendation was wrong, and the reason it was wrong is that it
argued about the wrong property.

**Confidentiality is not the point.** MIDI effect commands are not secret, and
the link stays inside VLAN 20. On that basis "no TLS" looked defensible.

**Authentication is the point.** Right now anything on VLAN 20 that can reach
`192.168.20.210:5000` can drive the pedal. NetworkPolicy constrains what the
*cluster* may talk to; it does nothing about the other hosts on that segment,
and VLAN 20 is not a two-host link — it holds four Pis, the PC, and whatever
else lands there. **mTLS makes the pedal answer only to the `midi` pod**, which
is a real control rather than a checkbox.

The estate already has the right tool and it was built for exactly this. From
`cluster/cert-manager/clusterissuer-internal-ca.yaml`:

> For machine-to-machine services that do not need public trust. Cheaper, no
> rate limits, and it is how mTLS gets bootstrapped later if a mesh ever
> arrives.

**The real cost is renewal on a Windows host**, not the crypto. cert-manager
cannot renew a certificate that lives on a Windows box, and a cert expiring
mid-stream stops the pedal responding. Handle it by issuing from `internal-ca`
with a long duration and folding installation into `midi-pc-deploy.yaml`, which
already deploys to that host — renewal becomes a re-run of a playbook that
exists, on a calendar reminder, rather than a new mechanism.

The pod side is trivial: it mounts the internal CA from the cluster to verify
the server, and presents its own `internal-ca`-issued cert as the client.

**Do it after the cluster half is migrated and working, not during.** Getting
`midi` running under Argo CD and getting mTLS onto a Windows service are two
debugging problems, and combining them means neither failure is legible.

### M4 — Keep dev and prod, and extend the toggle to every service. **Yes — but not the way it works today.**

The idea is right and it pays for itself twice: one environment running at a
time roughly halves the tenant footprint, which turns **F5**'s 92% quota fit
into comfortable headroom.

**The current mechanism cannot survive the move**, and this is the same problem
build 0003 carried forward. `chat-set-environment.yaml` runs
`kubectl scale deployment --replicas=0/1`. Under Argo CD with auto-sync that is
a fight it loses: the manifest in git says one replica, so the next
reconciliation puts it back. It also needs `deployments/scale`, which
`policy/tenants/README.md` deliberately does not grant a tenant credential —
precisely so a tenant cannot fight the reconciliation loop.

**Under GitOps the replica count belongs to git.** So the toggle becomes a
committed value, not an imperative command:

- one `active-env` value committed in `apps/eightbitsaxlounge/`
- each environment's manifests take their replica count from it — the inactive
  one renders `replicas: 0`
- the workflow's job is to *commit the flip*, then let Argo CD converge

That is strictly better than what exists: the toggle is auditable (it is a
commit), it needs no cluster credential at all, it cannot drift back, and it
covers every service rather than just `chat`. It also closes the carried
`chat-set-environment.yaml` item by deleting the problem instead of reworking
it.

Worth confirming during migration: `db` and `state` hold **state**. Scaling
CouchDB and NATS to zero with the rest is probably wanted — the whole point is
that nothing runs — but their PVCs persist, so decide explicitly whether the
inactive environment keeps its data (it should) and whether both environments
need their own copies (they already have separate PVCs, so yes).

---

## Still open

- **F1 is done** — the repo transferred to `nineteenseventytwo` on 2026-09-07.
  The local clone this migration ran from already carries the
  `nineteenseventytwo/` remote (checked 2026-09-12) — nothing to update there.
- **M4's toggle mechanism ended up different from what this section
  recommends.** The plan below argues for a git-committed replica flip
  specifically because `kubectl scale` loses the fight with Argo's
  auto-sync. What actually shipped (2026-09-12) is the imperative version
  anyway — `chat-set-environment.yaml` fixed to actually reach the cluster,
  paired with an `ignoreDifferences` entry on `Deployment/eightbitsaxlounge-
  chat`'s `/spec/replicas` in `cluster/argocd/applications/100-apps.yaml` so
  selfHeal stops fighting it. Chosen live, in response to a direct ask for a
  toggle usable "without accessing cluster directly or raising a PR" — a
  real trade-off against this plan's own reasoning (broader-access
  credential, not commit-auditable), not an oversight. It also went further
  than a toggle for `chat` alone: `db`/`state`/`data`/`midi`/`overlay` all run
  in both `dev` and `prod` permanently now, since none of them ever needed
  the exclusivity `chat` genuinely has (see
  `apps/eightbitsaxlounge/README.md`).
- Whether the two scheduled scans move to hosted runners, given M1's
  off-by-default cluster — still open, and out of scope for
  eightbitsaxlounge specifically: this migration did not adopt an
  off-by-default cluster, so the failure mode M1 describes doesn't apply to
  this tenant, but it may still apply platform-wide.
- Whether `platform` and `cloud` get `required_status_checks` at the same time
  as the app repo (M2) — still open. Checked 2026-09-12: `eightbitsaxlounge`
  has the full set; `platform` has everything except
  `required_status_checks`; `cloud` has `required_status_checks` but not
  `required_signatures`. Neither matches `eightbitsaxlounge`'s ruleset yet.

---

## Appendix — diagnosing the Windows MIDI service

For the M3/F9 pre-flight: establish whether the Windows half is running, which
version it is running, and whether deployment has been failing silently. Run
these on the PC in an **elevated PowerShell**.

The layout `midi-pc-deploy.yaml` builds:

```
C:\Tools\nssm\nssm.exe                       the service manager
C:\Services\Midi\{dev,prod}\<version>\       one directory per deployed version
C:\Services\Midi\{dev,prod}\current    -->   symlink to the active version
C:\Services\Midi\logs\MidiApi-{Dev,Prod}-std{out,err}.log
```

Services are `MidiApi-Dev` (port 5000) and `MidiApi-Prod` (port 5001).

### 1. What is actually running

```powershell
$nssm = "C:\Tools\nssm\nssm.exe"
foreach ($s in "MidiApi-Dev","MidiApi-Prod") {
  "$s : " + (& $nssm status $s 2>&1)
}
Get-Service MidiApi-* | Format-Table Name,Status,StartType
Get-NetTCPConnection -State Listen |
  Where-Object LocalPort -in 5000,5001 |
  Select-Object LocalAddress,LocalPort,OwningProcess
```

`SERVICE_RUNNING` plus a listener on `0.0.0.0` is healthy. A listener bound to
`127.0.0.1` only would explain the cluster being unable to reach it while the
service looks fine locally.

### 2. Which version — this is the one that exposes a silent failure

```powershell
foreach ($e in "dev","prod") {
  $base = "C:\Services\Midi\$e"
  "--- $e"
  (Get-Item "$base\current" -ErrorAction SilentlyContinue).Target
  Get-ChildItem $base -Directory | Select-Object Name,CreationTime
  Get-ChildItem $base -Filter *.tar.gz -ErrorAction SilentlyContinue |
    Select-Object Name,Length,CreationTime
}
```

Compare the symlink target against `midi/version.txt` in the repo (currently
**4.0.2**). **The expected failure mode is that `current` points at an older
version than the repo**: the service keeps running the last good build while
every deployment since has failed. Leftover `.tar.gz` files, or a version
directory with no `.exe` inside it, mean the download or extraction step is
where it breaks.

### 3. The logs

```powershell
foreach ($n in "MidiApi-Dev","MidiApi-Prod") {
  "===== $n"
  Get-Content "C:\Services\Midi\logs\$n-stderr.log" -Tail 40 -ErrorAction SilentlyContinue
  Get-Content "C:\Services\Midi\logs\$n-stdout.log" -Tail 20 -ErrorAction SilentlyContinue
}
Get-EventLog -LogName Application -Newest 40 |
  Where-Object Source -match "MidiApi|nssm|\.NET" |
  Format-Table TimeGenerated,EntryType,Message -Wrap
```

A stderr log whose newest entry is months old is itself the finding — it means
the process has not restarted since, which is consistent with "running happily,
never redeployed".

### 4. Is the pedal actually there

The service can be perfectly healthy and still not drive anything if the USB
device moved or re-enumerated:

```powershell
Get-PnpDevice -Class MEDIA -Status OK |
  Select-Object FriendlyName,InstanceId
```

Expect the **One Series Ventris Reverb** (the name `MIDI_DEVICE_NAME` uses). If
it is absent or renamed, the API is up and the pedal is unreachable — a
different fault with the same symptom.

### 5. Reachability, from both ends

```powershell
# on the PC — does it answer locally
Invoke-WebRequest http://localhost:5001/health -UseBasicParsing |
  Select-Object StatusCode
# and is the firewall open on the LAN side
Get-NetFirewallRule -Enabled True -Direction Inbound |
  Where-Object DisplayName -match "Midi|5000|5001"
```

```bash
# from a Pi on VLAN 20 — does it answer across the network
curl -sS -m 5 -o /dev/null -w '%{http_code}\n' http://192.168.20.210:5001/health
```

Local 200 with a cross-network failure is a Windows Firewall or bind-address
problem. Both failing is the service. The PC's address changed from
`192.168.68.50` to `192.168.20.210`, so any firewall rule scoped to the old
subnet will now deny — a strong candidate for the silent breakage.

### 6. Clearing it

Once the fault is known:

```powershell
$nssm = "C:\Tools\nssm\nssm.exe"
& $nssm stop   MidiApi-Prod
& $nssm restart MidiApi-Prod
& $nssm status  MidiApi-Prod

# full reinstall of the service definition only — leaves deployed files alone
& $nssm remove MidiApi-Prod confirm
```

Then re-run `midi-pc-deploy.yaml` **after** fixing `init-pc.yaml`'s address
(`192.168.68.50` → `192.168.20.210`) and .NET version (`9.0` → `10`), so the
redeploy is against correct facts rather than reproducing the drift.

**Capture the answers before changing anything.** Whether this was already
broken is the single fact that makes the cluster-side migration debuggable —
once `midi` is running under Argo CD, a failure here is indistinguishable from a
failure there.
