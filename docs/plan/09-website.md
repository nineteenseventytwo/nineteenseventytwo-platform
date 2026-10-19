# 09 — The website

_Written 2026-09-25. The execution plan for [07](07-completion-plan.md)'s
Phase 8, and the thing [06](06-programme-status.md)'s Block 3 — "the entire
'host a website, public stuff and a private login' objective" — has been
waiting for since 2026-09-07._

Verified against `nineteenseventytwo-cloud` at `4b97159`,
`nineteenseventytwo-platform` at `11bd2af`,
`nineteenseventytwo-eightbitsaxlounge` at `64ad1a1`, and the org's live SCP and
RCP definitions.

---

## What changed since D2

[D2](06-programme-status.md#d2--where-the-static-site-is-hosted) decided the
hosting on 2026-09-07: **S3 + CloudFront with Origin Access Control**, defined
in the cloud repo, deployed by a GitHub OIDC role, with Cloudflare Pages as the
explicit fallback. That decision stands and nothing found here disturbs it.

What has changed is **what the site is**. Phase 8.3 describes a portfolio piece
about the AWS estate — "the project showcase, the architecture, and the threat
each decision mitigates". The site now being built is a **personal site**: live
music near me, an 80s/90s anime watch list, 8bsl, other projects, in a
deliberately 1996 visual register. The platform estate becomes **one entry on
the projects page**, not the subject of the site.

This matters for one reason and no others. D2's tiebreak was that S3 +
CloudFront "produces more evidence of the skill being demonstrated — and the
site is a portfolio piece whose subject is the AWS estate it would then be
hosted in". That second clause is no longer true. The first still is: OAC, a
deny-non-TLS bucket policy, a response-headers policy and an OIDC deploy are
four real artefacts either way, and cost remains a wash. **Amend D2's reasoning
in the ADR; do not reopen its decision.**

Phase 8.3's bullet — "Pages: project showcase, the architecture, and the threat
each decision mitigates" — is superseded by the page table below. The content
is not dropped; it becomes the platform entry under Projects.

---

## The pages

| Page | Exposure | Content source | How it changes |
|---|---|---|---|
| Landing | public | hand-written, links out | rarely, by commit |
| Upcoming events | public | `events.json` in the bucket | **weekly, by job** |
| Anime | public | content collection in the repo | by commit, when you finish something |
| 8 Bit Sax Lounge | public | hand-written + links to Twitch | by commit |
| Projects | public | content collection — SaxFlash, composer, **the platform estate** | by commit |
| Dashboard — 8bsl service health | **private** | live, from the cluster | continuously, at request time |

The split is exactly [D2](07-completion-plan.md#d2--where-the-public-site-lives-shapes-phase-8)'s:
everything public is static and off-cluster, so a build 0005 never takes it
down; the dashboard is in-cluster behind Cloudflare Access → Tunnel, because a
cluster dashboard has no reason to exist when the cluster does not.

**The public half does not depend on Phase 8.1 or 8.2.** The tunnel and Access
are prerequisites for the dashboard only. The public site can ship end to end
while the tunnel work has not started, and it should — it is the half with a
deadline-shaped reason to exist.

---

## Findings

Ten things this trips over. Three are clearances — checked so nobody re-derives
them — and three are ordering constraints.

### F1 — The RCP does **not** block CloudFront's OAC access. Cleared.

This was the one expected blocker and it is not one.
`EnforceOrgPrincipals` denies `s3:*` to any principal outside the org, with a
`NotResource` carve-out for only the two JWKS discovery paths. OAC reaches the
bucket as the **`cloudfront.amazonaws.com` service principal**, which is not in
the org — so on the face of it the RCP denies the origin fetch and the site
serves 403 on every object.

It does not, because both statements in
`policies/rcp/enforce-org-principals.json.tftpl` carry
`"BoolIfExists": {"aws:PrincipalIsAWSService": "false"}`. The deny does not
apply to AWS service principals. Confirmed by reading the template, not by
assuming the common pattern.

**Do not remove that condition**, and note in the bucket's file header that the
site depends on it. It reads like belt-and-braces and it is load-bearing.

### F2 — `us-east-1` is allowed, so the ACM certificate is fine. Cleared.

CloudFront requires its certificate in `us-east-1`. `config/aws.json` sets
`regions.allowed` to `["eu-west-2", "us-east-1"]`, so
`DenyRegionsOutsideAllowlist` permits the issuance. Already asserted in D2;
re-confirmed here against the live config.

### F3 — `DenyExpensiveResources` touches nothing in this build. Cleared.

The denied action list contains no `s3:`, `cloudfront:` or `acm:` action. Also
noted for later: it denies `bedrock:CreateProvisionedModelThroughput` but **not**
on-demand `bedrock:InvokeModel` — so the deferred model half of the events
agent (W3) has no SCP obstacle when it arrives, provided it stays on-demand.

### F4 — The site cannot live in the sandbox account.

06 records the intent to "build app infra in sandbox, prove the guardrails do
not block it, then widen", and that instinct is right in general. It does not
apply here: `SandboxExtraRestrictions` exists because **the sandbox is nuked on
a schedule**, and a website that disappears on a cron is not a website.

The site's bucket, distribution and certificate go in **`platform-prod`**,
alongside the JWKS bucket that is already there for the same reason. The
guardrail-proving that 06 wanted still happens — it happens in prod, on first
apply, which is where F1 and F2 would have bitten.

### F5 — The deploy needs its own OIDC role. Do not reuse `gha-tf-apply`.

`modules/aws-github-oidc-role` asserts `token.actions.githubusercontent.com:sub`
with `StringEquals` against an exact list, and a variable validation **rejects
any subject containing `*`**. The existing `gha-tf-apply` holds the permissions
to apply the estate's Terraform. Handing a content-deploy workflow that role
would mean a site-copy job holding apply rights over the whole account.

Instead: a **second role from the same module**, with a policy scoped to
`s3:PutObject`/`DeleteObject`/`ListBucket` on the site bucket and
`cloudfront:CreateInvalidation` on the one distribution. Nothing else.

**Build the subject with the numeric IDs, not the slugs.** GitHub's `sub` claim
is `repo:org@org_id/repo@repo_id:...`, and
`modules/aws-account-ci/main.tf` already constructs it that way with the warning
attached: a trust policy built from slugs alone *silently never matches*, and
every `AssumeRoleWithWebIdentity` call fails with `AccessDenied`. There is no
error pointing at the cause. The site role's subject is therefore:

```
repo:nineteenseventytwo@314148597/nineteenseventytwo-web@1386955017:environment:aws-prod
```

**Recorded 2026-09-25** in `config/aws.json` as a new top-level `site` block —
`repo`, `repo_id`, `environment`, `hostname` — kept separate from `github`
because `github` means *the repo that owns the Terraform*, and the `tags` output
derives its `repo` tag from it. Read it through the cfg module's new `site`
output.

### F6 — The CNAME warning in the federation doc does **not** apply here.

[06-aws-federation.md](../06-aws-federation.md) explains at length why the JWKS
bucket needed a Cloudflare Worker rather than a CNAME: the S3 website endpoint
is HTTP-only and the bucket policy denies non-TLS, while the REST endpoint
presents a certificate for `*.s3.eu-west-2.amazonaws.com` that a proxied CNAME
cannot validate against.

**None of that constrains CloudFront.** The distribution serves the custom
hostname under its own ACM certificate, so a Cloudflare CNAME to the
distribution validates normally end to end at Full (strict). No Worker, no
SSL downgrade, no SNI override.

This is written down because the federation doc is the only prior art for
"point Cloudflare at AWS" in the estate, its warning is emphatic, and it looks
like it generalises. It does not.

### F7 — The events page is dynamic data on a static site.

Solve it with data, not with a rebuild. The weekly job writes **`events.json`
to the same bucket**; the page fetches it at load and renders client-side.

The alternative — the job commits to the repo and triggers a site rebuild — is
worse here: it couples content freshness to CI availability, puts a bot in the
commit history of a repo with branch protection, and buys nothing, because the
data has no need to be in git.

It also degrades correctly. If the job's host is down, the page serves the last
`events.json` and says how old it is. Stale is a legible failure; missing is
not. **Render the `generated_at` timestamp on the page** — it is the whole
reason this shape is safe.

### F8 — The dashboard is down exactly when it is interesting.

An in-cluster dashboard reporting cluster health reports nothing when the
cluster is gone, which is the case you most want it for. That is acceptable,
but only if it is deliberate:

- **In-cluster (recommended, W5).** Honest about its own dependency, and it is
  the thing that proves the Access → Tunnel path end to end. When the cluster
  is down, Cloudflare Access serves its own error and that *is* the signal.
- **Static, from a published JSON.** Survives the cluster, but then it is a
  second `events.json` pattern reporting stale state, and stale health data is
  actively misleading in a way stale gig listings are not.

Take the first. If cluster-down needs to page you, that is Alertmanager's job,
not a web page's — and it is Phase 5 work, not this.

### F9 — The events scraper is the only component making arbitrary outbound calls.

Everything else in this build talks to AWS, Cloudflare or GitHub. The scraper
talks to whatever venue sites it is pointed at, which has two consequences:

1. **Egress control.** Phase 7 enforces Squid on VLAN 20. A CronJob in-cluster
   scraping arbitrary hosts either goes through the proxy or is an exception to
   it, and an exception written for convenience is how egress control dies.
   Decide with W3, and if it runs in-cluster, it goes through Squid.
2. **Courtesy and terms.** Honour `robots.txt`, one request at a time with a
   real delay, a `User-Agent` that identifies the bot and links to the repo,
   and cache aggressively — venue listings change weekly at most, so a weekly
   scrape with conditional requests is proportionate.

Prefer a venue's own feed where one exists — iCal, RSS, a JSON endpoint behind
the listings page. Several listing platforms expose one. Scraping HTML is the
fallback, per venue, not the default.

### F10 — A strict CSP and a 1996 aesthetic will fight, unless you decide now.

8.3 lists a response-headers policy for HSTS and CSP. The 90s idiom —
`<marquee>`, inline `style=`, `onclick=`, a `<table>` holding the layout — is
mostly harmless nostalgia, but the inline attributes specifically are what
force `unsafe-inline` into the CSP, and a CSP with `unsafe-inline` is a header,
not a control.

The aesthetic does not actually require them. Tiled backgrounds, Comic Sans,
beveled borders, animated dividers, a hit counter, starfield GIFs and the
entire visual vocabulary live perfectly well in an external stylesheet.

**Build it with external CSS and external JS from the first commit**, and keep
`script-src 'self'` with no `unsafe-inline`. Retrofitting a CSP onto a site
already full of inline handlers is a rewrite, and the honest outcome of
attempting it late is that the CSP gets loosened instead.

*(The hit counter should be real, and it should be a Lambda@Edge or CloudFront
Function against a DynamoDB counter. It is period-correct and it is the
cheapest possible excuse to use CloudFront Functions.)*

---

## Decisions — settled 2026-09-25

All five. Nothing here is waiting on an answer.

### W1 — The hostnames. **Decided: `sev.` and `dash.`**

- Public site: **`sev.eightbitsaxlounge.com`**
- Private dashboard: **`dash.eightbitsaxlounge.com`**

A subdomain of `eightbitsaxlounge.com` rather than a new zone, since that is
the only zone in the estate — the registrar, DNS, DNS-01 issuance and the JWKS
Worker all sit on it, and a second zone buys nothing but a renewal date. Both
names are flat, matching the existing `oidc.` convention.

**Changed 2026-10-19:** the public name is `sev.`, replacing the `mark.`
first chosen here (itself picked over `home.`). Nothing had been built against
`mark.` beyond the `site` block in `config/aws.json`, which changes with it.

Worth naming the cost plainly, since it is the one thing the name cannot fix:
a personal site at a subdomain of a project's domain still reads as a sub-page
of that project, and `sev.eightbitsaxlounge.com` makes that relationship more
visible rather than less. Accepted deliberately. If the site ever becomes
something you hand to someone, revisit it then — it is a DNS record and a
certificate, not a rebuild, and the whole site is portable to an apex on a day's
notice.

### W2 — Astro, not Hugo. **Recommended.**

8.3 said "Astro or Hugo". Take Astro, for two reasons specific to this site:
content collections with typed frontmatter fit the anime and projects pages
exactly, and Astro ships **zero JavaScript by default**, which keeps F10's
strict CSP cheap rather than a thing you maintain. The events page's fetch is
then the only script on the site, and it is one file.

### W3 — The events job runs in GitHub Actions, not the cluster. **Recommended.**

A scheduled workflow, weekly, writing `events.json` to the bucket through the
same OIDC role pattern as F5.

The cluster alternative (a CronJob with IRSA, which `modules/aws-cluster-oidc-role`
already supports) is tempting because the plumbing exists. Reject it here: it
makes the public site's freshness depend on the cluster, which is the exact
coupling D2's split exists to prevent, and it drags F9's egress question into
Phase 7's Squid enforcement for no benefit. The job needs no GPU, no cluster
state and no local network.

**Rules-first, per the decision already taken.** Week one is a watchlist —
artists, genres, and venues — matched against scraped listings, with no model
anywhere in it. Define the scoring step behind an interface with one
implementation now (`RulesScorer`), so the model implementation drops in later
without touching the scraper or the publisher.

This deliberately does not wait on D1. The GPU host, Ollama and the arm64
question are all unresolved and the PC work is parked; the events page has no
reason to be held behind any of it. When inference does arrive — local or
on-demand Bedrock per F3 — it changes one class.

### W4 — Cloudflare proxied, not DNS-only. **Recommended.**

Orange-cloud the record. It keeps the CloudFront domain out of public DNS, puts
the WAF and analytics you already have in front of the origin, and matches how
every other hostname in the zone is served. F6 confirms Full (strict) validates
against the ACM certificate, so there is no SSL compromise in it.

The cost is two caches to purge on deploy. The deploy workflow already
invalidates CloudFront; add the Cloudflare purge to the same step so they never
drift apart.

### W5 — The dashboard is an in-cluster app behind Access. **Recommended.** See F8.

Start narrower than "cluster health": **the six 8bsl services and their state**
— running, crashing, stopped, unknown — read from the Kubernetes API with a
ServiceAccount holding `get`/`list`/`watch` on pods and deployments in the two
8bsl namespaces, **and nothing else**. A dashboard with cluster-wide read is a
credential worth stealing; one scoped to two namespaces is not.

"Unknown when the cluster is not reachable" is a real state and should render
as one, not as an empty table.

---

## Sequence

Roughly 40h. Phase 8's original ~20h covered the tunnel, Access and a showcase
page; the content pages and the events pipeline are genuinely additional work,
and the estimate says so rather than absorbing them silently.

### W.0 — Prerequisites _(~3h)_

- [x] Create `nineteenseventytwo-web` **in the org**, public, with the same
      branch protection, required checks and no self-hosted runner labels that
      [F1 of 08](08-eightbitsaxlounge-migration.md#f1--the-repo-is-not-in-the-organisation)
      had to retrofit. Do it right at creation; it costs nothing now.
      **Done 2026-10-19** — public, `main` ruleset (signed commits, PR
      required, no force-push or deletion). The required status check is
      added with W.2's build job; one that no workflow reports blocks every PR.
- [x] Record its repo ID in `config/aws.json` (F5). **Done 2026-09-25** —
      `site` block, ID `1386955017`.
- [x] ADR: the site, the D2 amendment from "What changed since D2", W1–W5.
      **Done 2026-10-19** — [ADR-0018](../decisions/ADR-0018-personal-website.md).

### W.1 — Infrastructure _(~8h, cloud repo)_

- [ ] Site bucket in `platform-prod` (F4): SSE, public access block on, versioning
- [ ] Bucket policy: OAC service principal with `aws:SourceArn` on the
      distribution, plus deny `aws:SecureTransport=false`
- [ ] Note in the file header that the RCP's `PrincipalIsAWSService` condition
      is what makes this work (F1)
- [ ] ACM certificate for `sev.eightbitsaxlounge.com` in `us-east-1`, DNS-01
      through the existing Cloudflare setup
- [ ] CloudFront: OAC, default root object, SPA-safe 404 handling, and a
      response-headers policy — HSTS, CSP per F10, `X-Content-Type-Options`,
      `Referrer-Policy`, `Permissions-Policy`
- [ ] The scoped deploy role (F5)
- [ ] `sev` DNS record, CNAME to the distribution, proxied (W4)

**Gate:** `curl https://sev.eightbitsaxlounge.com` from outside the lab and
get a 200; `curl` the S3 REST endpoint directly and get a 403.

### W.2 — Site skeleton and the public shell _(~8h, web repo)_

- [ ] Astro, external CSS/JS only (F10), content collections typed for anime
      and projects
- [ ] The 90s design system as an actual stylesheet — palette, tiles, bevels,
      dividers — so the pages are content, not styling
- [ ] Landing page and navigation
- [ ] Deploy workflow: build, sync to S3, invalidate CloudFront, purge
      Cloudflare (W4)

**Gate:** a commit to `main` is live on `sev.eightbitsaxlounge.com` within a
minute, and the CSP reports no violations in the browser console.

### W.3 — The content pages _(~8h)_

- [ ] **Projects** — SaxFlash, composer, 8bsl, and the platform estate entry
      that absorbs the old 8.3 showcase: the architecture, the ADRs, the threat
      each decision mitigates
- [ ] **8bsl** — what it is, how it works, links to the channel; the technical
      detail is a genuine draw here, so include the chat → NATS → MIDI path
- [ ] **Anime** — watched (alphabetical): one paragraph, one screenshot, one
      quote; then To Watch (alphabetical). Screenshots are used for criticism
      and review, so **credit the title and year on every image** and keep them
      to one per entry — that is what the exception expects, and it is good
      page design anyway.

**Gate:** all four public pages render at phone width without horizontal
scroll. The 90s register is not an excuse for a fixed 800px table.

### W.4 — The events pipeline _(~9h)_

- [ ] Venue list with, per venue, its preferred source — feed if one exists,
      HTML as fallback (F9)
- [ ] Scraper: conditional requests, one at a time, identifying `User-Agent`,
      `robots.txt` honoured
- [ ] Watchlist config — artists, genres, venues — in the repo, editable by PR
- [ ] `Scorer` interface with `RulesScorer` as its one implementation (W3)
- [ ] Publisher: `events.json` with `generated_at`, written to the bucket
- [ ] Weekly scheduled workflow, plus `workflow_dispatch` so you can run it by hand
- [ ] Events page: fetch, render, **show the data's age** (F7)

**Gate:** the job runs unattended on schedule, the page shows this week's gigs,
and a deliberately broken venue source degrades to "last updated N days ago"
rather than an empty or erroring page.

### W.5 — The private half _(~10h)_ — this is 07's Phase 8.1 and 8.2

- [ ] `cloudflared` per [8.1](07-completion-plan.md#81--cloudflare-tunnel): own
      namespace, credentials by ExternalSecret from Vault, default-deny plus a
      scoped allow to the Gateway only
- [ ] Route one low-value hostname first and confirm the path before `dash.`
- [ ] Cloudflare Access per 8.2, and **confirm the JWT is validated, not merely
      present** — 8.2 is explicit that an origin reachable around the proxy
      makes Access decoration
- [ ] The dashboard app: namespace-scoped ServiceAccount, two namespaces, read
      only (W5)
- [ ] Record whether internal Unbound overrides keep bypassing Access from
      VLAN 20 — 8.2 asks for this decision to be written down, not just taken

**Gate (8.2's, unchanged):** the public site is reachable from a phone on
mobile data; `dash.` is reachable only after an Access challenge; nothing is
reachable by hitting the home IP directly; the router still has zero inbound
port-forwards.

---

## Still open

- **Whether the public site waits for the tunnel.** It should not, and this
  plan assumes it does not. W.1–W.4 have no dependency on W.5; the only reason
  to sequence them together is if Phase 8 is being tracked as one block, and
  that is a reporting preference, not a constraint.
- **What else goes behind Access.** 8.2 names Grafana and Argo CD. This plan
  adds `dash.` and touches neither, deliberately — one new hostname through a
  new tunnel is the right size for a first cutover. Do the other two after.
- **SaxFlash has no repo.** The projects entry can be prose and photographs,
  but if the code is going public it is a fifth repo needing the same org
  treatment as W.0. Not blocking; worth knowing before the page implies a link
  that does not exist.
- **The model half of the events scorer.** Deferred by decision, not by
  oversight (W3). Revisit when D1 resolves or when Bedrock is turned on —
  whichever comes first, and F3 confirms neither is blocked by an SCP.
