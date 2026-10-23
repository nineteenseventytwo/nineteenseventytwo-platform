# ADR-0019: The org's repositories go private, on GitHub Team

**Status:** Accepted
**Date:** 2026-10-23
**Supersedes:** [ADR-0013](ADR-0013-platform-repo-public.md)

## Context

ADR-0013 made this repo public for showcase value, extending the reasoning
ADR-0010 had accepted for `eightbitsaxlounge`; the other org repos followed.
It accepted two costs to get there: the fork-PR path into self-hosted runners
became closed by workflow convention rather than by the repo being
unreachable, and the lab's topology, addressing and secret *structure* became
public.

The showcase now has a better home. The personal site (ADR-0018) carries a
Projects page, where an architecture diagram explains the estate better than a
repo browser does, and anyone who wants the code can ask for it. Meanwhile a
public repo kept one cost nobody had priced: on 2026-10-23 a full-history
secret scan found a live Twitch stream key that had sat in
`eightbitsaxlounge` for seven months - reset the same day, but public the
whole time.

The thing that made public free is also what makes private not free.
GitHub's Free plan enforces rulesets only on public repositories (it refused
to create one on `nineteenseventytwo-web` while that repo was private), and
code scanning and secret-scanning push protection are free only for public
repositories.

## Decision

**All five org repositories are private: `nineteenseventytwo-platform`,
`-cloud`, `-composer`, `-eightbitsaxlounge` and `-web`. The org is on
GitHub Team** (one seat), which keeps the rulesets - signed commits,
pull requests, required status checks - enforced on private repositories and
raises Actions minutes to 3,000 a month.

What public-repo features did is replaced, not dropped:

| Was (public, free) | Now |
|---|---|
| Code scanning: Trivy/Checkov SARIF in the Security tab, and its "new alerts" PR check | Job-summary tables. Blocking where a finding is always wrong (secrets, any severity; cloud's Checkov); advisory where there is a standing backlog (platform's Checkov, Trivy vuln/misconfig) |
| Secret-scanning push protection | Trivy's secret scanner as a blocking step in every repo's required PR check |
| Weekly image scan into the Security tab | The same scan, per-image critical/high table in the run summary, SARIF kept as run artifacts, Slack linking to the run |

## Consequences

- **The fork-PR path into self-hosted runners is closed at the root again**:
  nobody outside the org can open a pull request. ADR-0010's rule - no
  self-hosted label on a `pull_request` job - stays as defence in depth, and
  costs nothing to keep.
- **Topology and secret structure stop being published.** Not retroactively:
  these repos were public for weeks to months, and clones, forks and archives
  of that history exist. Anything sensitive in that history must be treated
  as already disclosed; going private protects only what comes after.
- **New findings are no longer tracked across runs.** Code scanning remembered
  an alert, deduplicated it and noticed when it was fixed; job summaries show
  each run's state and nothing more. The daily Prowler report and the weekly
  image scan are the trend lines that remain.
- **A plain exit code cannot tell a new finding from an old one**, which is
  why the backlog scans are advisory. A PR that adds a HIGH misconfiguration
  no longer fails on its own; Checkov (blocking in cloud) and review carry
  that.
- **Cost:** GitHub Team for one seat. Actions usage was roughly 1,500-2,500
  billable minutes a month at the time; self-hosted ARC runners do not count.
- **Links break** wherever they point into these repos: the site's "view
  source" link, project `repo:` links, and the web README's link to the plan.
  Removed with this change; the Projects page gets a diagram instead.
- The org's runner-group "allow public repositories" setting (ADR-0013) is no
  longer needed and should be turned off.

## Alternatives considered

- **Private on GitHub Free.** No cost, but rulesets stop being enforced -
  unsigned and unreviewed commits could reach `main` - and Actions minutes cap
  at 2,000 a month, close to current use. Rejected: it removes the controls
  that stop a bad change landing.
- **Paid GitHub Code Security** to keep code scanning and push protection on
  private repos. Priced per active committer and far more than this estate's
  scale warrants; the replacements above cover what was used.
- **Stay public** (ADR-0013). Rejected by the owner: the showcase moves to the
  site.
- **Hybrid** - only `platform` and `cloud` private. They hold the most
  sensitive content, but splitting conventions across repos (where findings
  live, which links work, which controls apply) costs more than the remaining
  public value.
