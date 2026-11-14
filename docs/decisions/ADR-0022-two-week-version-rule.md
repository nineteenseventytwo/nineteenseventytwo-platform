# ADR-0022: Pin versions at least two weeks old; security fixes are the stated exception

**Status:** Accepted
**Date:** 2026-11-14 (practised since the initial build; recorded now)

## Context

Every repo in the org pins its versions. That covers base images by digest,
Helm charts, Python, npm, NuGet and Go packages, Terraform providers,
GitHub Actions by SHA, and the binaries baked into our images: kubectl,
helm, sops, age and the GitHub runner. A pin is a choice of which release
to trust, and the newest release is the one least tested by anyone.

The rule has been followed since the first build, but only by habit. It
appears in a few comments, such as `cluster/falco/values.yaml` ("9.2.1 was a
week old") and eightbitsaxlounge's `chat/CHANGELOG.md`, and nowhere as a
rule. Nothing enforced it. Each PR's release dates were checked by hand.

Two things on 2026-11-14 made that gap concrete:

- The cloud repo's terraform Dependabot job ran successfully for the first
  time (cloud #46). It opened seven PRs proposing `hashicorp/aws` 6.72.0,
  released ten days earlier. All seven passed CI.
- Two days before, the platform took Cilium 1.20.4 early, for its security
  fixes. Its chart had dropped the `envoy.xdsMode` default, and the gateway
  was down for 37 minutes (#278, #280). It was a security exception, so the
  rule would not have stopped it. It is still the failure this rule exists
  to make rare.

## Decision

**A pinned version must have been released upstream at least 14 days before
it is merged.** The clock starts at the upstream release date, not at the
date the PR is opened.

**Exception: a release that fixes a vulnerability affecting what we run may
be taken early.** The PR description must say so and name the advisory. The
pinned file must carry a comment with the reason, so the exception is
visible to whoever next reads the pin. Example: eightbitsaxlounge `midi/Dockerfile`,
ASP.NET Core 10.0.15 for CVE-2026-114146/-114147/-114149, taken at two days
old.

**Where Dependabot runs, it enforces the rule** with
`cooldown: {default-days: 14}` on every ecosystem. Cooldown applies only to
version updates. Dependabot security updates ignore it, which matches the
exception above.

| Repo | Updates | Enforced by |
|---|---|---|
| `nineteenseventytwo-cloud` | Dependabot: github-actions, terraform | cooldown (cloud #54) |
| `nineteenseventytwo-eightbitsaxlounge` | Dependabot: docker, gomod, npm, nuget, pip, github-actions | cooldown (eightbitsaxlounge #115) |
| `nineteenseventytwo-web` | Dependabot: npm, github-actions | cooldown (web #25) |
| `nineteenseventytwo-platform` | by hand, prompted by `image-vuln-scan.yml` and upstream releases | the reviewer checks release dates |
| `nineteenseventytwo-composer` | by hand | the reviewer checks release dates |

## Consequences

- **We usually skip a broken release rather than discover it.** Compromised
  packages, maintainer-account takeovers and plain regressions tend to be
  reported and yanked or patched within days. Two weeks lets other people
  find them first. When a `.1` follows quickly, we take the `.1` directly.
- **We run up to two weeks behind upstream on everything that is not a
  security fix.** That includes fixes we would like, such as a bug fix in a
  chart. Wait, or argue it as a security exception if it honestly is one. Do
  not stretch "security" to cover a convenience.
- **Dependabot PRs can still arrive out of policy** where cooldown cannot
  see a publication date. Dependabot warns "Cooldown could not be applied"
  on some docker bases. Check those by hand.
- **A security exception is not exempt from review.** It skips the waiting
  period, not the render-diff, scan and dev-first steps. Cilium 1.20.4 shows
  what an early release can carry. For a Helm chart, compare
  `helm template` output from the old and new versions with our values
  before the PR.
- **Repos without Dependabot rely on the reviewer.** Adding Dependabot (or
  Renovate) to platform and composer would move them into the enforced rows.
  Not done yet. Platform's versions span Helm charts in Argo Applications,
  Ansible vars and Dockerfile ARGs, and Dependabot covers only some of
  those.

## Alternatives considered

- **No delay; take releases as they land.** Fewer stale versions, but every
  bad release reaches us on day one, on a three-node lab with no staging
  cluster. Rejected.
- **A longer delay (30 days).** Lowers the risk further, but leaves a wider
  window on non-security bugs and makes bumps bigger and rarer. Two weeks
  covers the period in which most bad releases are caught. Revisit if a bad
  release ever gets past the 14 days.
- **No exception for security fixes.** It would leave a known, published
  vulnerability in place for two weeks to guard against a hypothetical one.
  Rejected. The exception is required to be written down instead.
- **Enforce only by review.** That was the state until now, and it worked
  only as long as someone remembered to check release dates. The cloud PRs
  showed automation proposes whatever is newest unless told otherwise.
