# ADR-0018: The public site is a static Astro build on S3 + CloudFront; the private dashboard is in-cluster

**Status:** Accepted
**Date:** 2026-10-19

## Context

Phase 8 of [07](../plan/07-completion-plan.md) is "host a website, public
stuff and a private login". [06's D2](../plan/06-programme-status.md#d2--where-the-static-site-is-hosted)
chose the hosting on 2026-09-07 — S3 + CloudFront with Origin Access Control,
Cloudflare Pages as the fallback — and broke the tie on the grounds that the
site was a portfolio piece **about the AWS estate it would be hosted in**.

That is no longer what the site is. [09](../plan/09-website.md) re-scoped it to
a **personal site**: live music near me, an 80s/90s anime watch list, 8 Bit Sax
Lounge, other projects, in a deliberately 1996 visual register. The platform
estate becomes one entry on the Projects page. One half of D2's tiebreak is
therefore gone, and something has to say whether the decision falls with it.

The constraints that are not obvious, all verified in 09's findings:

- The RCP's `EnforceOrgPrincipals` would deny CloudFront's OAC fetch, except
  that both statements carry `BoolIfExists aws:PrincipalIsAWSService = false`.
  That condition is load-bearing for this site (F1).
- The sandbox account is nuked on a schedule, so the site cannot live there
  despite 06's build-in-sandbox-first intent (F4).
- `gha-tf-apply` holds apply rights over the whole account, and the OIDC role
  module rejects wildcard subjects. A content deploy cannot share it (F5).
- A strict CSP and the 90s idiom of inline `style=` and `onclick=` are
  incompatible unless the choice is made before the first page exists (F10).

## Decision

**D2's decision stands; its reasoning is amended.** The public site is S3 +
CloudFront with OAC in `platform-prod`, defined in `nineteenseventytwo-cloud`.
The surviving half of the tiebreak is enough on its own: OAC, a deny-non-TLS
bucket policy, a response-headers policy and an OIDC deploy are four real
controls whatever the site's subject, and cost is still a wash. Within that:

- **W1** — the public site is `sev.eightbitsaxlounge.com`; the private
  dashboard is `dash.eightbitsaxlounge.com`. No new zone.
- **W2** — Astro, with external CSS and JS only and `script-src 'self'` with no
  `unsafe-inline` from the first commit.
- **W3** — the weekly events job runs in GitHub Actions, rules-first behind a
  `Scorer` interface, and writes `events.json` to the site bucket. It does not
  rebuild the site and does not run in the cluster.
- **W4** — the `sev` record is Cloudflare-proxied, CNAME to the distribution,
  Full (strict). The deploy purges both caches in one step.
- **W5** — the dashboard is an in-cluster app behind Cloudflare Access →
  Tunnel, reading pod and deployment state in the two 8bsl namespaces only.

Deploys use a **second OIDC role** scoped to the site bucket and the one
distribution, with a subject built from numeric IDs:
`repo:nineteenseventytwo@314148597/nineteenseventytwo-web@1386955017:environment:aws-prod`.
The site's repo is recorded as the `site` block in the cloud repo's
`config/aws.json`, kept apart from `github`, which means the repo that owns the
Terraform.

## Consequences

- The public half does not depend on the tunnel or Access. W.1–W.4 can ship
  while 07's 8.1 and 8.2 have not started, and should.
- A cluster rebuild never takes the public site down. The dashboard does go
  down with the cluster; that is deliberate (09 F8), and "unknown" is a state
  it must render, not an empty table.
- The RCP's `PrincipalIsAWSService` condition becomes something the site
  depends on. It reads like belt-and-braces, so the bucket's file header says
  otherwise. Removing it serves 403 on every object with no error pointing at
  the cause.
- Two caches on every deploy. A deploy that invalidates CloudFront but not
  Cloudflare serves stale pages for as long as Cloudflare's TTL, so the purge
  lives in the same step as the invalidation, never a separate one.
- The events page is only as fresh as the last successful job. It shows
  `generated_at`, so staleness is visible rather than silent.
- The scraper is the one component making arbitrary outbound calls. Running
  it in Actions keeps it out of Phase 7's Squid enforcement; if it ever moves
  in-cluster, it goes through the proxy.
- The 1996 aesthetic costs more effort than it would with inline attributes.
  That is the price of a CSP that is a control rather than a header.
- `sev.eightbitsaxlounge.com` reads as a sub-page of 8bsl. Accepted; moving
  to an apex later is a DNS record and a certificate, not a rebuild.
- `nineteenseventytwo-web` is public, in the org, with signed commits and PRs
  required on `main` from its first commit. Its required status check is added
  when the build job exists, not before — a required check that no workflow
  reports blocks every PR.

## Alternatives considered

- **Cloudflare Pages.** Faster to working, and the same account already holds
  DNS and DNS-01. Rejected for the same reason as in D2, minus the
  portfolio-subject half: it demonstrates nothing about the controls. It stays
  the fallback, taken deliberately and recorded here if taken.
- **Hugo.** Equally capable of emitting a static site. Astro wins on typed
  content collections, which fit the anime and projects pages, and on shipping
  no JavaScript by default, which keeps the strict CSP cheap.
- **The events job as an in-cluster CronJob with IRSA.** The plumbing already
  exists. Rejected because it couples the public site's freshness to the
  cluster, which is the coupling D2's split exists to prevent.
- **The events job commits data and triggers a rebuild.** Couples freshness to
  CI and puts a bot in a branch-protected history for data that has no need to
  be in git.
- **Reusing `gha-tf-apply` for the deploy.** Hands a content-copy job apply
  rights over the account.
- **A static dashboard from a published JSON.** Survives the cluster, but stale
  health data misleads in a way stale gig listings do not.
- **A new zone.** A second zone buys nothing but a renewal date.
- **`mark.` or `home.`** 09 first chose `mark.` over `home.`; it was changed
  to `sev.` on 2026-10-19, before anything was built against it.
