# 07 — Completion plan

_Written 2026-09-05. The successor to `03-rebuild-timeline.md`, which ran out at
its Phase 5. Continues that numbering: this document is Phases 6 through 12._

Where [06-programme-status.md](06-programme-status.md) says what is done, this
says what finishing looks like and in what order. It absorbs everything still
open in [05-provisioning-completion-plan.md](05-provisioning-completion-plan.md)
(WP-5 and WP-7 in particular), the unfinished half of the 90-day plan, and the
items carried into build 0004.

**Budget assumption:** 6–8 focused hours a week, as before. The whole of this
document is roughly **150 hours**, so **20–24 weeks**. That is worth knowing up
front: the remaining work is comparable in size to everything built so far, and
sequencing it badly is the main way it does not get done.

Every phase has a **gate**, in the sense `REBUILD.md` uses the word: a check
that either passes or the phase is not finished. Gates are not suggestions.

---

## Ordering principle

```
Decisions made → Workloads land → Egress closed → Exposed (public + private)
→ Hybrid → CNAPP closed and proven → Published → GCP (stretch)
```

Two dependencies drive that order and are worth stating, because they are not
obvious:

- **Egress enforcement comes after the migration, not before.** The allowlist in
  `docs/01-network-validation.md` was drafted from what the *platform* needs.
  Six application services are about to add destinations nobody has enumerated.
  Enforcing first means debugging the migration and the proxy at the same time,
  and every symptom looks like the other problem.
- **The drill comes last among the security items,** because a detection and
  response exercise against an empty cluster proves nothing. It needs real
  workloads, real egress paths, and real exposure to be a real drill.

Cloud-side work (Phase 9's Terraform, Phase 11's GCP) touches nothing the
cluster depends on and can fill weeks when the migration is mid-flight and you
want something that will not break it.

---

## Decisions to make first

Four. Three block a phase; one shapes it. Each has a recommendation and the
reason for it — take them or overrule them, but record which in an ADR, because
every one of these is the kind of choice that gets silently re-litigated later.

### D1 — Where composer's inference runs *(blocks Phase 6.3)*

The GPU is an x86 dual-boot PC. [ADR-0011](../decisions/ADR-0011-arm64-only.md)
makes the cluster arm64-only and says populating the `gpu` group needs a new
ADR, not a config edit.

| Option | What it costs |
|---|---|
| **(a)** Join the PC as an x86 GPU worker | Multi-arch builds become **mandatory for every image the cluster runs, forever** — plus NVIDIA device plugin, runtime class, taints and tolerations. And the node is offline whenever Windows is booted for the midi-api. A permanent tax on all future work, for one intermittent node. |
| **(b)** Composer API in-cluster (arm64); Ollama stays off-cluster on the PC, reached over one explicitly-allowed path | Keeps ADR-0011 intact. Ships composer now. The LLM call becomes a network dependency with a NetworkPolicy allow-pair, which is a normal thing the cluster already knows how to express. |
| **(c)** Inference in AWS Bedrock; no GPU node at all | Costs per token. Needs an IRSA role for the composer pod — a pattern that already exists and works. **This is literally the 90-day plan's stated deliverable** ("build it locally on Ollama, then write up how I'd port it to Bedrock"). |
| **(d)** Tailscale-join the GPU node | Not a different architecture — a reachability variant of (b). Only needed if the PC ends up somewhere VLAN 20 cannot reach it. |

**DECIDED 2026-09-07 — (b).** Composer's API runs in the cluster on arm64 and
delivers work to the GPU host outside it. (c), a Bedrock backend behind the
same interface, follows in Phase 11 and turns the pair into the comparison
write-up. (a) is rejected.

Original recommendation, kept for the ADR:
(b) is the only option that ships composer without either reopening ADR-0011 or
making the cluster's behaviour depend on which operating system someone last
booted. Then doing (c) as a second inference backend behind the same interface
turns the pair into the comparison write-up the 90-day plan asked for — which is
worth more than either backend alone. (a) buys one intermittent node and charges
every future image for it.

### D2 — Where the public site lives *(shapes Phase 8)*

**PARTLY DECIDED 2026-09-07.** The *split* is accepted: the static public site
is hosted off-cluster, and the private authenticated area sits behind
**Cloudflare Access → Tunnel → in-cluster**. The static half is hosted on
**S3 + CloudFront with Origin Access Control**, defined in the cloud repo and
deployed by the existing GitHub OIDC role — both options cost effectively £0
here, so the tiebreak was which produces more evidence of the skill the site is
demonstrating. **Cloudflare Pages stays the explicit fallback if Phase 8 runs
late.** Comparison:
[06 §D2](06-programme-status.md#d2--where-the-static-site-is-hosted).

The reason to resist putting the public site on-prem: it is the portfolio, and a
portfolio hosted on the cluster is down exactly when you are rebuilding the
cluster — which is the thing the portfolio is showing off. Build 0004 should not
take the showcase offline. The split also means you build and can talk about
*both* patterns, and neither one is redundant with the other.

### D3 — Tailscale or WireGuard for the hybrid link *(shapes Phase 9)*

**DECIDED 2026-09-07 — self-managed WireGuard, terminated on OPNsense.**

Worth stating precisely, because the two are not alternatives in the way the
original plan implied: **Tailscale *is* WireGuard.** It is a managed control
plane — key distribution, NAT traversal, ACLs, an identity model — over the
WireGuard data plane. The choice is not protocol versus protocol; it is
self-managed versus managed.

Self-managed is the right call here, and for a reason the original plan did not
have available to it: **OPNsense has first-class WireGuard support**, and this
is a *site*-to-site link, so it belongs at the site boundary rather than in a
pod or on a node. Terminating on the firewall means the tunnel inherits the
rule set, the logging and the interface model that already govern every other
path in and out of VLAN 20 — and it keeps cluster→cloud connectivity off the
critical path of a cluster workload. It also means no third-party control plane
holds keys to the lab, which is easier to defend under "who can touch what,
proven" than a managed mesh is.

The cost is manual key distribution (two peers — trivial) and no NAT-traversal
assistance (not needed; OPNsense holds the public IP in bridge mode).

⚠️ **This decision collides with two existing controls. See
[Phase 9's blocker](#phase-9-blocker-the-vpc-has-no-path-to-the-internet)
before starting Phase 9 — it is a design change, not a config edit.**

### D4 — How much GCP *(scopes Phase 11)*

**DECIDED 2026-09-07 — GCP is a stretch goal and goes last, after everything
else is up and running.** Reframed accordingly: not "mirror the AWS slice" as a
Phase-1 learning exercise, but *"the platform works end to end — now let's build
some redundancy in GCP and learn hybrid-cloud and GCP concepts on top of
something real."* That is a better exercise anyway, because there is then an
actual workload to make redundant rather than a hypothetical one.

It moves to **Phase 12, after consolidation.** Scope when it arrives stays
narrow — Workload Identity Federation, Cloud KMS, one Private Service Connect
endpoint, and the Org Policy analogues of the SCPs that matter. Explicitly not
a second landing zone. The 90-day plan's goal for 1C was fluency in the
*mapping*, not a second production estate. Three services and the comparison
table deliver that. A second org structure, a second set of guardrails and a
second CI path would cost as much as the AWS side did and prove the same point
twice.

---

## Immediate — things already due

Revised 2026-09-07 after checking each item against the repos rather than
against build 0003's carried list, which had gone stale in two places.

- [ ] **Decide the two staged SCPs on evidence, not on the calendar.** The
      "clean CloudTrail week" rule is the wrong instrument for this step and
      the observation window has already told you everything it can — see
      [06 §The SCP window](06-programme-status.md#why-the-quiet-week-proves-nothing-here).
      What to do instead: query CloudTrail in `security`, `shared` and
      `platform-prod` for the API calls those accounts *actually* make, and
      check them against the two policies by hand. Then attach — knowing that
      **Prowler's own all-regions scan will start generating expected
      `AccessDenied` entries** the moment `DenyRegionsOutsideAllowlist` reaches
      the root, and that those are correct behaviour, not a regression.
- [x] ~~**Land `bootstrap/cloud-init/render.sh`'s fix.**~~ **Already done** —
      commit `464b91f`, 2026-09-04, "fix: render.sh age-key mount path and
      output_dir chdir resolution". Build 0003's log lists it as carried
      because the log was closed before the fix landed. The carried list is
      wrong, not the repo.
- [x] **Document Argo CD's manual-sync semantics** — done 2026-09-07,
      `cluster/README.md`, "Nudging a sync by hand: three things that do not
      work the way they look". All three gotchas, plus a symptom→cause→fix
      table, since the failure mode was always reaching for the wrong one.
- [x] **`KUBECONFIG` — the runbook gap is fixed.** The scoped RBAC
      (`policy/40-ci-argocd-sync.yaml`) and the swap procedure
      (`04-secrets.md`) were both already done and correct; nothing sequenced
      them, so `REBUILD.md` stored cluster-admin at step 3.3 and never came
      back. New step **4.7** does the swap, 3.3 says plainly that it is
      temporary, and Phase F's evidence list covers it.
- [ ] **Determine what the live secret actually holds** — not knowable from the
      repos (GitHub secrets are write-only). Either read the apiserver audit
      log for the username `deploy-cluster.yml` last authenticated as, or just
      re-run the swap. See
      [06 §The kubeconfig question](06-programme-status.md#the-kubeconfig-question).
- [x] **A LimitRange coverage check** — done 2026-09-07,
      `tests/verify-limitrange.sh` + `make verify-limitrange`, modelled on
      `verify-default-deny.sh` including its unreachable-cluster guard.
- [ ] **Close the `gateway` namespace gap the new check found.** `gateway` is
      the only namespace outside the documented exemptions with **neither a
      LimitRange nor a ResourceQuota**, and it runs the Cilium Gateway's Envoy
      pods. Unlike its default-deny exemption, which is deliberate and
      explained, nothing says this one is.
      **Do not add a LimitRange to it blind.** Build 0002 lost an evening to
      exactly that move: `longhorn-system`'s new LimitRange `default.cpu` of
      `200m` landed under instance-manager's existing explicit `400m` *request*,
      which is invalid at admission and retries forever with no pod ever
      created. Check first:

      ```bash
      kubectl -n gateway get pods -o jsonpath=\
        '{range .items[*].spec.containers[*]}{.name}{"\t"}{.resources}{"\n"}{end}'
      ```

      Size the `default` above anything already requested there, then add both
      the LimitRange and a ResourceQuota — or write down why `gateway` is
      exempt from both, in the same place the NetworkPolicy exemption is
      explained.

**Gate:** `make verify-default-deny` and `make verify-limitrange` both exit 0;
the cloud repo's README has no stale SCP TODO; `cluster/README.md` documents
all three Argo CD gotchas.

---

## Phase 6 — Workloads land _(~40h, 6–8 weeks)_

**Goal: `apps/` stops being empty. The platform starts carrying the thing it was
built to carry.**

This is the largest block, it has been carried unchanged since build 0001, and
every prerequisite for it now exists.

### 6.1 — eightbitsaxlounge, six services, one at a time

Order is fixed by dependency: `db-couchdb` → `state-nats` → `chat` → `midi-api`
→ `security` → `overlay`. Each one lands and is verified before the next starts.
Per service:

- [ ] Manifests into `apps/eightbitsaxlounge/dev/`, then `prod/` once dev holds
- [ ] `image:` repointed at GHCR
- [ ] Requests sized to fit the tenant `ResourceQuota` — they are deliberately
      tight; raise them in a PR with a reason, never by editing the cluster
- [ ] Every `Secret` converted to an `ExternalSecret` against
      `kv/tenants/eightbitsaxlounge/*`
- [ ] Its NetworkPolicy allow-pair added — default-deny is already in force, so
      a service that works without one is a service whose policy is wrong
- [ ] An `HTTPRoute` attached to the shared Gateway for anything with a UI

Two known snags, both already diagnosed:

- [ ] **Verify every chart pin before its next apply** (`helm search repo <chart>
      --versions`). WP-1.1 was the first casualty of an unverified pin and is
      probably not the last.
- [ ] **Rewrite `chat-set-environment.yaml` to restart by deleting the Pod**,
      not by scaling the Deployment to zero and back. It is the one app-repo
      playbook that cannot run under the tenant CI credential, and granting it
      `deployments/scale` would let a tenant credential fight Argo CD's
      reconciliation loop.

### 6.2 — Retire `eightbitsaxlounge/server`

- [ ] Decide each of the old repo's workflows: repoint at the ARC scale set,
      move to a hosted runner, or delete. The `midi-data-*` and
      `chat-set-environment` ones are runtime operations that stay in the app
      repo — they still need a runner that exists.
- [ ] Replace `server/README.md` with a stub pointing at the platform docs
- [ ] Work the mapping table in `05-migration.md` to zero
- [ ] **Delete `eightbitsaxlounge/server`.** Not archive — delete. It is the
      only way the stale 192.168.68.0/24 and Flannel references stop being
      found by the next person reading the repo, including you.

### 6.3 — Composer standup _(needs D1)_

- [ ] Write the ADR recording D1 before any code
- [ ] `policy/tenants/composer.yaml` — namespaces, quota, LimitRange,
      default-deny, tenant RBAC. Copy the eightbitsaxlounge tenant as the
      template. Merge and let it sync **before** any workload
- [ ] `apps/composer/dev/` — the composer API and musicxml-tools
- [ ] The inference path per D1: a NetworkPolicy allow-pair to the GPU host, or
      an IRSA role for Bedrock. Not both yet — the second backend is Phase 12
- [ ] **Fix `composer/infra/README.md`** (WP-7). It documents a cluster that no
      longer exists: 192.168.68.0/24, Flannel, and a `server` layer that Phase
      6.2 just deleted. Correct it or replace it with a banner
- [ ] Delete or rewrite `composer/infra/k8s/` — the platform repo owns
      manifests now (ADR-0012), and a second set in the app repo is exactly the
      ambiguity that ADR exists to remove

### 6.4 — Turn the egress proxy on in log-only mode

Not enforcement — observation. Set the proxy configs so traffic is *logged*
while the migration is happening, and collect the real destination list as the
services come up. Phase 7 enforces against that list rather than a guess.

**Gate:** every service `Synced/Healthy` in both environments; `apps/` is
non-empty and the `100-apps` ApplicationSet has something to discover;
`eightbitsaxlounge/server` is gone; `tests/verify-default-deny.sh` and the new
LimitRange check both pass across the new namespaces.

---

## Phase 7 — Egress control _(~8h, 1–2 weeks)_

**Goal: the third proxy type, and the last unfinished item from the original
Phase 1.**

- [ ] Squid on OPNsense, allowlisting VLAN 20 outbound against the list in
      `docs/01-network-validation.md` **plus** everything Phase 6.4 observed
- [ ] Flip `egress_proxy_enabled: true` and converge. All three configs — shell
      environment, Docker daemon, containerd — or you get three different
      confusing symptoms; `ansible/roles/docker` and `ansible/roles/kube_prereqs`
      already handle all three
- [ ] Re-run `make test-network` and the full node baseline
- [ ] Write the three-proxy-types decision record: reverse (Gateway), forward
      (Squid), ZTNA (Phase 8) — what each mitigates, and the cloud analogue of
      each. This was the 90-day plan's highest-leverage learning objective and
      it deserves the write-up, not just the config

**Gate:** a pod attempting a non-allowlisted destination is denied and the denial
is in Squid's log; every workload from Phase 6 still runs.

---

## Phase 8 — Exposure: public and private _(~20h, 3 weeks)_

**Goal: something outside the house can reach the lab, on purpose, with identity
in front of it. Still no inbound ports.**

### 8.1 — Cloudflare Tunnel

- [ ] `cloudflared` as a Deployment in the cluster, credentials via
      ExternalSecret from Vault
- [ ] Its own namespace, default-deny plus a scoped allow to the Gateway only —
      a tunnel that can reach everything is a hole, not a control
- [ ] Route one low-value hostname through it first and confirm the path end to
      end before adding anything that matters

### 8.2 — Cloudflare Access

- [ ] Access policy (email OTP to start) in front of Grafana and Argo CD
- [ ] Confirm the Access JWT is actually validated, not merely present — an
      identity-aware proxy you can bypass by hitting the origin directly is
      decoration. The origin must be unreachable except through the tunnel
- [ ] Decide and record whether internal Unbound overrides keep bypassing Access
      from VLAN 20, or whether the tunnel becomes the only path

### 8.3 — The public site _(needs D2)_

- [ ] Astro or Hugo static site → S3 + CloudFront (D2), in the cloud repo:
      OAC so the bucket is never public, a deny-non-TLS bucket policy, a
      response-headers policy for HSTS/CSP, ACM cert in `us-east-1` (allowed —
      checked against `regions.allowed`), deploy via the existing OIDC role
- [ ] Pages: project showcase, the architecture, and — the part that matters for
      the job — **the threat each decision mitigates**. The ADRs are already
      written; this is the public-facing edit of them
- [ ] Wire the DNS, confirm TLS, confirm it survives the cluster being down
      (test it: that is the whole argument for D2's split)

**Gate:** the public site is reachable from a phone on mobile data; Grafana is
reachable only after an Access challenge; nothing is reachable by hitting a home
IP directly; the router still has zero inbound port-forwards.

---

## Phase 9 — Hybrid _(~24h, 3–4 weeks)_

**Goal: on-prem and AWS reach each other privately, and one cloud node joins the
on-prem control plane.**

### Phase 9 blocker: the VPC has no path to the internet

**Found 2026-09-07, while recording D3. Resolve this before Phase 9 starts —
it is a design change to two committed controls, not a config edit.**

`live/aws/platform-prod/vpc.tf` is private-only on purpose: no internet
gateway, no NAT (denied by SCP, and deliberately — a NAT Gateway is an
unmonitored egress path), one free S3 gateway endpoint. That shape is correct
for workloads. It is **incompatible with terminating a tunnel in that VPC**,
and the incompatibility is not specific to WireGuard — it defeats Tailscale
equally, so D3 did not cause it and switching back would not avoid it:

- A WireGuard peer in that VPC has no route to the internet, so it cannot reach
  OPNsense to establish the tunnel.
- Making OPNsense the initiator instead does not help: the AWS side still needs
  a reachable, stable endpoint, which needs an internet gateway and an address.
- `DenyExpensiveResources` denies **`ec2:AllocateAddress`** — so the Elastic IP
  a stable tunnel endpoint requires cannot be created. It also denies
  `ec2:CreateVpnGateway` and `ec2:CreateVpnConnection`, which closes the
  managed-AWS-VPN alternative the original plan named as the "graduate to the
  enterprise version" step.

So Phase 9 needs three decisions made together, and each is a real trade-off
against a control that exists for a reason:

1. **A public subnet and internet gateway in `platform-prod`**, scoped to the
   tunnel endpoint alone, with the private subnets keeping their current shape.
   The security argument to write down: an IGW reachable only by one hardened
   host running one UDP listener is a smaller egress surface than a NAT Gateway
   serving everything, which is what the current comment rejects.
2. **A carve-out for `ec2:AllocateAddress`** — narrowed to `platform-prod`
   rather than removed. An EIP costs about \$3.60/month while attached and is
   charged when *unattached*, which is the cost the SCP was written to prevent;
   one deliberate, attached, monitored EIP is a different thing from an
   accidental pool of them.
3. **Whether the tunnel endpoint is the Graviton worker itself** (9.3) or a
   separate `t4g.nano`. Combining them is cheaper and one less instance;
   separating them means a burst workload cannot take the site-to-site link
   down with it. Recommend separating: the link is infrastructure, the worker
   is a workload, and they should not share a failure domain.

Do all three in one PR with the reasoning, or Phase 9 stalls at its first
`terraform apply` with an `AccessDenied` that looks like a bug.

### 9.1 — The link _(needs D3)_

- [ ] Tailscale subnet router bridging VLAN 20 ↔ the platform-prod VPC's private
      subnet
- [ ] It is an egress path — so it belongs in Phase 7's allowlist and needs a
      NetworkPolicy that says which pods may use it. A tunnel installed after
      egress control, and not registered with it, quietly undoes Phase 7

### 9.2 — Turn the VPC on

- [ ] Flip the gate in `live/aws/platform-prod/vpc.tf`. It is already the right
      shape: private-only, no internet gateway, no NAT (denied by SCP, and
      deliberately — a NAT Gateway is an unmonitored egress path), S3 gateway
      endpoint only
- [ ] Test both directions: a cluster pod reaching S3 over the link, and an EC2
      instance reaching an internal service VIP

### 9.3 — A Graviton worker

- [ ] Join one small Graviton instance as a tainted worker. arm64, so
      ADR-0011 holds and multi-arch is still not needed — this is why the
      arm64-only decision keeps paying
- [ ] Taint it so only burst work lands there. Schedule exactly one job onto it
      and prove it ran
- [ ] **Cost gate:** confirm what it costs per month before leaving it up, and
      confirm the budget alarm would catch it if it changed

**Gate:** a pod on-prem reaches a private AWS resource without traversing the
internet; a job scheduled by the Pi control plane runs on a cloud node; the
monthly cost is written down.

---

## Phase 10 — Close the CNAPP, then prove it _(~24h, 3–4 weeks)_

**Goal: the last two pillars, findings that arrive somewhere a human looks, and
the drill.**

### 10.1 — Runtime detection

- [ ] Falco as a DaemonSet. On arm64 kubeadm, check the driver situation before
      committing an evening to it — the modern eBPF probe is the path
- [ ] Alerts into the existing Alertmanager → Slack route. Not a new
      notification channel: the point is one place findings land

### 10.2 — Schedule what is currently manual

- [ ] Kubescape as a CronJob, not a per-build hand-run. Compare against
      `docs/baseline-nsa.json` and alert on regression rather than on absolute
      score — [ADR-0017](../decisions/ADR-0017-kubescape-accepted-controls.md)
      already establishes which controls are accepted, so a regression is
      meaningful and a raw score is not

### 10.3 — Asset graph

- [ ] Steampipe or CloudQuery against the AWS org. One real query answered that
      would otherwise take an afternoon in the console — the attack-path
      question, e.g. "which roles in any account can be assumed from outside the
      org" — and write it down as the artefact

### 10.4 — Findings in one place

- [ ] Prowler's S3 findings, Trivy's weekly scan, Kubescape's regressions and
      Falco's alerts currently land in four unrelated places. Route them to one
      Grafana view. This is the part of a CNAPP that is actually hard, and the
      part interviews ask about: prioritisation, not collection

### 10.5 — The drill _(90-day plan 3B — the highest-signal missing item)_

- [ ] One deliberate, safe misconfiguration in the sandbox account or the
      cluster. Something Falco or GuardDuty *should* catch
- [ ] Do not tell yourself when. Measure the real detection time
- [ ] **Write the postmortem**: detection time, blast radius, fix, and the
      guardrail that prevents recurrence. Then build the guardrail
- [ ] File it as a build-log-style record — this project already has the
      discipline for exactly this shape of document

**Gate:** an injected misconfiguration was detected by a control you did not
touch, and a postmortem exists that names the guardrail that now prevents it.

---

## Phase 11 — Consolidate and publish _(~16h, 2 weeks)_

**Goal: the work becomes legible to someone who was not there.**

- [ ] **The Bedrock port** (D1's option (c), now the agreed follow-on to (b)) as composer's second inference
      backend behind the same interface, plus the write-up comparing it to
      Ollama on cost, latency and control. The 90-day plan called this "gold for
      week one of the job" and it is the one deliverable that is both technical
      work and a talking point
- [ ] Make composer actually agentic: `musicxml-tools` functions as
      tool definitions, the fixed pipeline as a plan → call → observe → revise
      loop, a critic step, and guardrails — max iterations, schema validation on
      tool output, a cost budget, and tracing. Build a small eval set first, or
      you are measuring vibes
- [ ] Two or three public write-ups. The strongest three this build has, in
      order: **IRSA on a cluster that is not EKS**, **what a failed rebuild
      taught the runbook** (build 0002 → 0003 is a genuinely good story with
      numbers), and **the OSS CNAPP**
- [ ] Architecture diagrams out of `diagrams/` and onto the site
- [ ] **Cost review**: what is running, what it costs per month, what gets torn
      down. Budgets and anomaly detection are already wired — this is the
      human-readable half
- [ ] The private Day-1 doc: questions for the new team, their tooling versus
      the lab equivalents, what to learn first

**Gate:** a stranger can read the public site and understand what was built and
what threat each piece mitigates, without access to any repo.

---

## Phase 12 — GCP, as a stretch goal _(~16h, 2–3 weeks)_ _(D4)_

**Goal: redundancy for something that actually runs, and GCP fluency on top of
it. Not a second estate, and not a prerequisite for anything above.**

Everything in Phases 6–11 is done before this starts. That is the point of
moving it: there is now a real workload to make redundant.

- [ ] Workload Identity Federation for GitHub Actions — the direct analogue of
      what the cloud repo already does, and the one that most reveals how the
      two providers differ
- [ ] Cloud KMS, one key
- [ ] One Private Service Connect endpoint
- [ ] Org Policies: the two or three that correspond to the SCPs that matter
      most (`DenyIAMUsersAndKeys` has a direct analogue and it is instructive)
- [ ] **The artefact is the comparison table**, filled in from having done it —
      not from documentation. That table was in the original target
      architecture with every row marked "To implement"; this is the phase that
      changes those rows

**Gate:** a GitHub Actions job obtains GCP credentials with no stored secret,
and the AWS↔GCP mapping table has no "to implement" rows left in its identity,
keys and private-networking sections.

---

## Definition of done, for the whole programme

The original documents get to be closed when all of these hold:

1. `apps/` carries every eightbitsaxlounge service and composer, reconciled by
   Argo CD, and `eightbitsaxlounge/server` no longer exists.
2. All three proxy types are in service: reverse, forward, ZTNA.
3. A public site is reachable from the internet and survives the cluster being
   rebuilt; a private area behind identity is reachable and cannot be bypassed.
4. On-prem and AWS reach each other privately, and at least one cloud node has
   run real work scheduled by the on-prem control plane.
5. All six CNAPP pillars are live, on a schedule, reporting into one place.
6. A detection-and-response drill has been run against controls you did not
   touch, and its postmortem names a guardrail that now exists.
7. The AWS↔GCP mapping table is filled in from experience.
8. Build 0004 has run the whole of `REBUILD.md` end to end **with the workloads
   in it** — the rebuild claim is only proven once what is being rebuilt is the
   real thing and not an empty cluster.

Item 8 is the one that ties it together, and it is why Phase 6 goes first.
