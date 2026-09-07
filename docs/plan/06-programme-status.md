# 06 — Programme status

_Written 2026-09-05, against the four repos as committed. Assessed against the
original planning set: the 90-day cloud security plan, `01-current-state-inventory`,
`02-target-architecture`, and `03-rebuild-timeline`._

**What this is verified against:** the contents of the four repositories at the
commits below — not the live cluster.
[05-provisioning-completion-plan.md](05-provisioning-completion-plan.md) did the
opposite and said so; this one is a repo-state read, and anything marked ✅ here
means *the code, config or record exists and is wired in*, not that it was
re-observed running today. Where a repo's own build log or plan asserts a live
verification, that is cited as the evidence rather than re-claimed.

| Repo | HEAD | Date |
|---|---|---|
| `nineteenseventytwo-platform` | `d6d9f71` | 2026-09-05 |
| `nineteenseventytwo-cloud` | `a57f6ee` | 2026-08-29 |
| `nineteenseventytwo-composer` | `7e8390c` | 2026-03-18 (+ uncommitted WIP) |
| `nineteenseventytwo-eightbitsaxlounge` | `7cb24af` | 2026-03-18 (+ uncommitted WIP) |

---

## The one-paragraph version

The security foundation is finished to a standard well beyond what the original
plan asked for. Everything the plan called "Phase 1 Foundations" — segmentation,
identity, encryption, guardrails, posture — is not only built but built twice,
proven by a from-scratch rebuild, and recorded in ADRs and build logs. What has
**not** happened is everything on the far side of the cluster boundary: nothing
in the lab is reachable from outside it, there is no on-prem↔cloud link, and the
two applications that were the reason for building any of this are still not
running on it. The programme is roughly **75% of the infrastructure and 10% of
the payload**.

---

## Original phases, current state

### Rebuild timeline (`03-rebuild-timeline.md`)

| Phase | Original goal | State |
|---|---|---|
| **0** — Accounts, domain, imaging | 4 Pis online, key-only SSH, accounts ready | ✅ **Done, superseded.** Manual imaging became `bootstrap/cloud-init/render.sh` + a template-render pattern; the hardening checklist became `ansible/roles/hardening`. All four boards are now RPi 5. |
| **1** — Network re-architecture | Segmented network, OPNsense in control | ✅ **Done except egress.** OPNsense on N100, bridge mode, VLANs 10/20/30/40, Kea + Unbound, default-deny inter-VLAN. The one-off "red-team pass" became `tests/network-check.sh` — a re-runnable matrix, which is strictly better. **Squid egress proxy is the sole miss** (see below). |
| **2** — CI/CD bootstrap | Pipeline that configures the fleet before the cluster exists | ✅ **Done, exceeded.** Containerised runner + containerised Ansible, SOPS+age, AWS OIDC for Actions. Went further: ARC scale sets in-cluster, cosign keyless signing, Checkov in lint. |
| **3** — Cluster, hardened from commit one | kubeadm + Cilium, security defaults before workloads | ✅ **Done, exceeded, and proven.** Default-deny everywhere with a test that asserts it, PSS, namespaced RBAC, etcd encryption *plus* a backup/rotation runbook, MetalLB, Longhorn. Plus items the plan never listed: kubelet-csr-approver, apiserver audit logging, Cilium Gateway API in place of ingress-nginx. |
| **4** — Services return, HTTPS-only | Every service redeployed via pipeline, TLS everywhere | ⚠️ **Platform half done, application half not started.** Gateway + cert-manager + Let's Encrypt DNS-01 all live; kube-prometheus-stack with Alertmanager → Slack; Trivy gate in CI. But `apps/` contains one README. The tenant namespaces, quotas, LimitRanges, default-deny policies, RBAC and the `100-apps` ApplicationSet all exist **and hold nothing**. |
| **5** — Security layers + hybrid + public site | Vault live, public site up, AWS both ways, detection running | ⚠️ **Split.** Vault and AWS massively exceeded; public site, tunnel, hybrid link and runtime detection all not started. Detail below. |

### Phase 5, broken out

Phase 5 was four unrelated things in one bucket, and they went four different ways.

| Phase 5 item | State | Note |
|---|---|---|
| Vault OSS on cluster | ✅ **Exceeded** | Raft on Longhorn, KMS auto-unseal, KV + k8s auth + SSH CA, External Secrets projecting into workloads. The plan stopped at "migrate workload secrets"; the build went on to complete an **SSH CA cutover and retire the static keys entirely** (build 0003, Phase E). |
| Minimal Terraform AWS landing zone | ✅ **Far exceeded** | The plan asked for "VPC, CloudTrail→S3 object-lock, GuardDuty, Security Hub, KMS CMK". What exists is a five-account organisation with OUs, SCPs *and* RCPs, org CloudTrail with Object Lock, org-wide GuardDuty with per-feature cost control, org-external Access Analyzer, two KMS CMKs, Terraform state isolated in its own account, CI-only apply behind an environment approval gate, budgets, anomaly detection, and CloudWatch alarms on root sign-in and break-glass assumption. |
| Cloudflare Tunnel + Access + public site | ❌ **Not started** | Zero references to `cloudflared` in any repo. Nothing in the lab is reachable from outside it. No public site exists in any form. |
| Hybrid link + cloud worker + Falco + the drill | ❌ **Not started** | No Tailscale or WireGuard on the platform side; the VPC exists in Terraform but is deliberately gated off; no Falco anywhere; no misconfiguration drill. |

### 90-day plan mapping

| Project | State |
|---|---|
| **1A** Network + the three proxy types | ⚠️ **1 of 3.** Reverse proxy ✅ (Cilium Gateway + cert-manager). Egress/forward proxy ❌ (`egress_proxy_enabled: false`). ZTNA/tunnel ❌ (no cloudflared, no Tailscale). Segmentation itself is done and exceeded — but the *proxy vocabulary* this project existed to teach is one-third delivered, and it was framed as the highest-leverage item in the plan. |
| **1B** AWS landing zone | ✅ **Exceeded.** Two deliberate divergences, both recorded: AWS Config + Security Hub dropped in favour of scheduled Prowler on cost grounds (cloud ADR-0005), and Secrets Manager dropped in favour of Vault. |
| **1C** GCP mirror | ❌ **Not started.** No GCP anything, in any repo. |
| **2A** Hybrid connectivity + mTLS | ❌ tunnel not built. Service mesh/mTLS was **declined, not missed** — ADR-0003 chose Cilium without a mesh, with reasons. That is a closed decision, not a gap. |
| **2B** Cloud worker nodes on the Pi control plane | ❌ **Not started.** `live/aws/platform-prod/vpc.tf` is written, private-only, NAT-free by design — and off. |
| **2C** Public + private showcase site | ❌ **Not started.** |
| **2D** Agentic composer | ❌ **Not started.** Composer is still the linear parse→split→transform→reassemble pipeline. No tool-calling, no agent loop, no critic, no eval set, no tracing. Recent WIP is on dataset prep and the LLM client, not the architecture. |
| **3A** OSS CNAPP | ⚠️ **4 of 6 pillars.** CSPM ✅ Prowler (scheduled CronJob, IRSA, findings to the security account). IaC ✅ Checkov in both repos' lint. Vuln + secrets ✅ Trivy at build **and** a weekly re-scan of what is actually running, plus cosign signing — beyond the plan. KSPM ✅ Kubescape, but run by hand per build, not scheduled. Runtime/CWPP ❌ no Falco. Asset graph ❌ no Steampipe/CloudQuery. |
| **3B** Detection & response drill | ❌ **Not started.** The single highest-signal missing item in the whole 90-day plan — it is what separates running scanners from doing the job. |
| **3C** Decision records and stakeholder reps | ✅ **Strongly delivered on the written half.** 17 platform ADRs, 6 cloud ADRs, 3 build logs, a conventions doc governing where explanation lives. The verbal half — the 2-minute summaries, the role-play reps — leaves no repo trace and is presumed not done. |
| **3D** Consolidate, publish, cost, Day-1 doc | ⚠️ Internal documentation is excellent. Nothing is public: no blog posts, no showcase, no architecture diagrams outside the repos (`diagrams/` holds drawio sources). Budgets and anomaly detection are wired, but the "what stays running and what it costs per month" writeup does not exist. |

---

## Built, and in no original plan

These matter more than the checklist above, because they are the parts a reader
of the original plan would not predict — and the parts worth talking about.

1. **IRSA on a cluster that is not EKS.** A public OIDC issuer at
   `oidc.eightbitsaxlounge.com`, JWKS in S3, a Cloudflare Worker in front, an
   IAM OIDC provider trusting it, and `pod-identity-webhook` injecting
   role ARNs per service account. One role per workload, each trusting exactly
   one service account. This is the hardest single thing in the build and it is
   **proven end to end** — Vault unseals with `Seal Type awskms`, which cannot
   happen unless the SA-token → STS → KMS chain works.
2. **Argo CD as the boundary, with the app repos holding no credential at all**
   (ADR-0012). The usual split is "platform owns the namespace, app owns what's
   in it"; this goes further — `apps/` lives in the platform repo, app repos
   build an image and stop. No kubeconfig, no `kubectl`, no deploy step, ever.
3. **SSH certificates replacing static keys, completed.** Vault SSH CA issuing
   five-minute certificates; `ansible-console` and `ansible-workstation` static
   keys retired. Most labs plan this and never finish it.
4. **Build logs as a discipline**, with `fix/` PR share as the health metric
   (0001: 80%, 0003: 31%). The runbook is corrected *from the log*, and build
   0002's failure — an SSH cutover that locked out three nodes — produced a
   push-gate in `REBUILD.md` Phase E that build 0003 then proved under real
   conditions.
5. **Staged SCP rollout with observation windows** — account, then OU, then
   root, each gated on a clean CloudTrail week. That is production change
   management, in a homelab.
6. **RCPs alongside SCPs** (`enforce-org-principals`, `enforce-tls`) — resource
   control policies are newer than the plan and are not in it.
7. **A weekly Trivy scan of the images actually running in the cluster**, not a
   hand-maintained list — closing the gap that build-time-only scanning leaves
   the moment a third-party chart is upgraded.
8. **Cilium Gateway API instead of ingress-nginx** (ADR-0015), with one Gateway,
   one pinned LB IP, and SNI-separated listeners.

---

## What is actually left

Six blocks. Two the user already named; four of comparable size that the
original documents contain but that have gone quiet.

| # | Block | Size | Why it is still open |
|---|---|---|---|
| **1** | **eightbitsaxlounge migration** — six services into `apps/`, then delete `eightbitsaxlounge/server` | Large | Carried unchanged through builds 0001, 0002 and 0003. Every prerequisite now exists; nothing blocks it but the work. |
| **2** | **Composer standup** | Large | Blocked on an unresolved decision, not on effort — see below. |
| **3** | **Public and private exposure** — cloudflared, Cloudflare Access, the showcase site | Medium | The entire "host a website, public stuff and a private login" objective. Untouched. |
| **4** | **Hybrid link and cloud worker** — subnet router, turn the VPC on, join a Graviton node | Medium | Terraform is written and gated off; the on-prem half does not exist. |
| **5** | **Close the CNAPP and prove it** — Falco, scheduled Kubescape, an asset-graph tool, findings in one place, and the misconfiguration drill | Medium | 3B is the highest-signal item in the 90-day plan and has no repo trace at all. |
| **6** | **Egress control and GCP** — enforce Squid on VLAN 20; mirror the identity/encryption slice into GCP | Small / Medium | Squid's plumbing is written and switched off. GCP is untouched. |

### The composer blocker, stated plainly

Composer needs GPU inference. The GPU is an x86 dual-boot PC. ADR-0011 makes
the cluster **arm64 only** and says populating the `gpu` inventory group
requires a new ADR, not a config edit. Meanwhile the live GPU work — the
`init-gpu-node` / `setup-tailscale` playbooks with uncommitted changes — sits
in `eightbitsaxlounge/server`, the layer that is being **deleted**, and targets
`192.168.68.0/24` and Flannel, a network and CNI that no longer exist.
`composer/infra/README.md` describes the same vanished world (WP-7).

So composer is not one task behind; it is behind a decision nobody has made.
Four options exist, and picking one is the first move — the completion plan
([07](07-completion-plan.md)) recommends one and explains why.

### Also outstanding, small

- **The staged SCPs' last step.** `DenyRegionsOutsideAllowlist` and
  `DenyExpensiveResources` moved to the Sandbox OU on 2026-08-29. The rule is
  a clean CloudTrail week before the root. That week elapsed on 2026-09-05 —
  **this is due now.**
- **Carried into build 0004** and still open: the Vault `revoke-self` mystery,
  a `check_mode: false` convention, and the `chat-set-environment.yaml` rewrite.
  Three others on that list have since closed — `render.sh` landed in
  `464b91f`, and the Argo CD sync semantics and the LimitRange coverage check
  were both written on 2026-09-07. See the appendix.
- **`KUBECONFIG` org secret** — the scoped RBAC and the swap procedure both
  exist; what was missing was any step sequencing them. Fixed in `REBUILD.md`
  (new step 4.7) on 2026-09-07. Whether the *live* secret currently holds the
  scoped credential or the admin one is not knowable from the repos — check the
  audit log or re-run the swap. See the appendix.


---

## Appendix — questions raised 2026-09-07

Four things the status read above got wrong or left unanswered, checked
against the repos.

### Why the quiet week proves nothing here

The rollout rule in `policies/README.md` is: sandbox account → Sandbox OU →
root, each after "CloudTrail has shown no unexpected `AccessDenied` for a
week". The challenge to it is correct: **the sandbox is empty, so a quiet week
there is absence of evidence, not evidence of absence.** Nothing has been
deployed in those accounts to be denied.

But the conclusion that follows is the opposite of reassuring. Look at what
each step actually changes:

| Step | Accounts affected | What runs there |
|---|---|---|
| 1. sandbox account | `sandbox` | nothing |
| 2. Sandbox OU | `sandbox` | still nothing |
| 3. **root** | `security`, `shared`, `platform-prod`, `sandbox` | **everything** |

(SCPs do not apply to the management account, so `mgmt` is unaffected
throughout.)

Steps 1 and 2 were the same test twice, over an empty account. **Step 3 is the
first one that touches anything real**, and the evidence gathered in steps 1
and 2 has close to zero predictive power for it. Waiting another week changes
nothing, because the thing being observed is still not being exercised.

The right instrument is not a longer window — it is an analysis, and the data
already exists. Those three real accounts *do* have a week of genuine activity
in CloudTrail: Terraform applies, daily Prowler scans, GuardDuty, KMS calls
every time Vault unseals, S3 from Longhorn backups, STS from every IRSA
assumption. Query what they actually call and check it against the two
policies by hand.

Two things that check will surface:

- **Prowler will start producing `AccessDenied` once the region deny is at the
  root** — it scans all regions by default, and every describe call outside
  `eu-west-2`/`us-east-1` will be denied. Those are expected and correct. A
  naive reading of "clean CloudTrail" afterwards will look like a regression
  and is not one. Decide now whether to scope Prowler to the allowed regions
  or accept the noise, so it is a known outcome rather than an alarm.
- **`DenyExpensiveResources` blocks Phase 9 outright** — `ec2:AllocateAddress`,
  `ec2:CreateVpnGateway` and `ec2:CreateVpnConnection` are all denied, and the
  hybrid link needs the first of those. Attaching at root before resolving that
  means the SCP has to be edited again a few weeks later. See
  [07's Phase 9 blocker](07-completion-plan.md#phase-9-blocker-the-vpc-has-no-path-to-the-internet).

The original intent — build app infra in sandbox, prove the guardrails do not
block it, then widen — is the right instinct and is still the right approach.
It just has not happened yet, because nothing was ever built in sandbox to
prove it against.

### D2 — where the static site is hosted

Both options are effectively **£0/month** at this scale, so cost does not
decide it.

| | Cloudflare Pages | S3 + CloudFront |
|---|---|---|
| Cost here | Free tier: unlimited bandwidth and requests, 500 builds/month, custom domains and TLS included. No meter to watch. | S3 storage for a static site is pennies; CloudFront's perpetual free tier covers 1 TB egress and 10M requests a month. Realistically £0, but it is metered and the budget alarm is the backstop. |
| Customisation of the site itself | Identical — both serve whatever Astro or Hugo emits. This is not a differentiator. | Identical. |
| Build/deploy | Native GitHub integration, per-PR preview deploys, build on push. Roughly an hour to working. | Build in Actions, sync to S3, invalidate the CloudFront cache. Maybe six hours to working, and invalidation is a real papercut. |
| Edge compute | Pages Functions on the Workers free tier | CloudFront Functions / Lambda@Edge |
| Compatibility with existing controls | Same Cloudflare account already holding the registrar, DNS, DNS-01 issuance and the JWKS Worker. One less provider. | Compatible: `us-east-1` is in `regions.allowed`, so the ACM cert CloudFront requires can be issued, and nothing in `DenyExpensiveResources` touches S3, CloudFront or ACM. Checked. |
| **What it demonstrates** | That you can push to git. | Origin Access Control so the bucket is never public, a deny-non-TLS bucket policy, a response-headers policy for HSTS/CSP, and a deploy running through the OIDC role that already exists — **four more artefacts on the showcase page, in the estate the showcase is about.** |

**DECIDED 2026-09-07 — S3 + CloudFront with OAC**, defined in the cloud repo and
deployed by the existing GitHub OIDC role, **with Cloudflare Pages as the
explicit fallback if Phase 8 is running late.** Since cost is a wash, the tiebreak is which
option produces more evidence of the skill being demonstrated — and the site is
a portfolio piece whose subject is the AWS estate it would then be hosted in.

The fallback is a real option, not a formality: if Phase 8 slips, the site
existing at all matters more than what building it proves. Take it deliberately
rather than by drift — and if you do, say so in the ADR.

Either way the D2 *split* stands: the public site is off-cluster so a rebuild
never takes the portfolio down, and the private area stays behind Cloudflare
Access → Tunnel → in-cluster.

### The kubeconfig question

**Corrected 2026-09-07 — my first read of this was wrong, and so was 05's
WP-3.3. Both for different reasons.**

The scoping work *is* done, and was done properly:

- `policy/40-ci-argocd-sync.yaml` creates a `ci-argocd-sync` ServiceAccount
  with a namespaced Role: `get`/`list`/`patch` on `applications.argoproj.io`
  in `argocd` only. Exactly the two operations `argocd-sync-wait` performs,
  plus a namespace `get` for its timeout-debug fallback.
- `04-secrets.md#replacing-the-kubeconfig-secret` documents the full swap
  procedure.
- The secret inventory already describes `KUBECONFIG` as carrying that Role,
  with the note "Not cluster-admin, and never was meant to be".

So "retire it" (05's WP-3.3) was wrong — it is load-bearing for
`deploy-cluster.yml` and `console` sits outside the cluster by design
([ADR-0007](../decisions/ADR-0007-console-outside-cluster.md)), so *some*
credential is unavoidable. And "it is full cluster-admin" (my read) was wrong
too — I inferred that from `make kubeconfig` writing the admin credential
without checking what the org secret was later replaced with.

**What is actually broken is the sequencing, and it is a runbook bug.**

`REBUILD.md` step 3.3 says "Store it as the org secret `KUBECONFIG`. Scope it —
do not hand out cluster-admin if you can avoid it." But 3.3 is in **Phase C**,
and `policy/40-ci-argocd-sync.yaml` is applied by Argo CD in **Phase D**. At
step 3.3 the `ci-argocd-sync` ServiceAccount does not exist yet. There is
nothing to scope to. The instruction is unfollowable at the point it is given.

And nothing later in the runbook came back for it — `kubeconfig` appeared
exactly twice in `REBUILD.md`, both in step 3.3, and Phase F's evidence list
did not mention it. The `[ ]` box in `04-secrets.md` was the only thing
tracking it, in a different document.

Build 0003's log records the predictable outcome, at step 3.3:

> This is a cluster-admin credential going into an org-wide GitHub secret —
> flagged for explicit sign-off rather than run automatically

**So the state of the live secret is genuinely unknown from the repos.** GitHub
Actions secrets are write-only, so it cannot be read back to settle it. Two
ways to find out:

1. **The apiserver audit log** — enabled in `ansible/roles/kube_control_plane`,
   and this is exactly what it is for. Check which username
   `deploy-cluster.yml`'s last run authenticated as:
   `system:serviceaccount:argocd:ci-argocd-sync` means the swap happened,
   `kubernetes-admin` means it did not.
2. **Just re-run the swap.** Cheap, and it settles the question either way.

**Fixed in the runbook 2026-09-07:** step 3.3 now states plainly that it is
staging a temporary cluster-admin credential and why it has to be; new step
**4.7** performs the swap once Argo CD has synced `policy/`; and Phase F's
evidence list now includes it. Without that, every future build re-introduces
the admin credential and relies on someone remembering an unticked box
somewhere else.

### `render.sh` did land

Build 0003's carried list is stale. The fix is committed: `464b91f`,
2026-09-04, *"fix: render.sh age-key mount path and output_dir chdir
resolution"*. The platform repo's working tree is clean. Nothing to do, and the
item should come off build 0004's carried list rather than being re-asked a
fourth time.
