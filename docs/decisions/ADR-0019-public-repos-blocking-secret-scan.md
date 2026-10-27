# ADR-0019: The repos stay public; secrets block in every repo's required check

**Status:** Accepted
**Date:** 2026-10-23 (recorded 2026-10-26)

## Context

On 2026-10-23 a full-history secret scan found a live Twitch stream key in
`eightbitsaxlounge` (`overlay/files/obs/profiles/.../service.json`), committed
2026-03-12 and public for seven months. It was reset on Twitch the same day and
removed in that repo's #98.

GitHub's secret-scanning push protection was already on and did not catch it:
push protection matches known provider token formats, and a stream key is not
one of them. Trivy's secret scanner was running, but advisory, so a finding
could not fail a pull request.

The first response was to make all five org repos private, on GitHub Team so
the rulesets would stay enforced (platform PR #219). That was closed unmerged
the same day. Going private would have cost:

- **Argo CD repo credentials** for a repo it currently reads anonymously.
- **Environment required reviewers.** On private repos these need GitHub
  Enterprise, and `cloud`'s apply gate depends on them.
- Possibly the **free hosted arm64 runners** every image build uses.

It would also have left the actual hole open. The key was already public, and
going private does not un-publish history.

Several commits in the app repos cite "platform ADR-0019" for the blocking scan,
but the draft by that number was the private-repos one, and it was never merged.
This record is the decision those commits actually implemented.

## Decision

**[ADR-0013](ADR-0013-platform-repo-public.md) stands: all five org repos stay
public.**

**Every repo runs Trivy's secret scanner as a blocking step, at every severity,
inside the job that is its required status check:**

| Repo | Required job | Step |
|---|---|---|
| `nineteenseventytwo-platform` | `lint.yml` → `security` | `Trivy secret scan (blocking)` |
| `nineteenseventytwo-cloud` | `lint.yml` → `security` | `Trivy secret scan (blocking)` |
| `nineteenseventytwo-composer` | `composer.yaml` → `test` | `Trivy secret scan (blocking)` |
| `nineteenseventytwo-eightbitsaxlounge` | `pr.yml` → `security` | `Trivy secret scan (blocking)` |
| `nineteenseventytwo-web` | `ci.yml` → `build` | `Trivy secret scan (blocking)` |

This is separate from the existing advisory Trivy scans, which stay as they are.
Those also cover vulnerabilities and misconfiguration, which carry a standing
backlog. A secret has no backlog: it is always wrong, so a single finding fails
the check.

## Consequences

- **A secret in any format Trivy knows, provider-specific or generic, now fails
  the PR.** Push protection is still on and catches tokens earlier, at push
  time. This is the second net, for the formats push protection does not cover.
- **A false positive blocks a merge.** The fix is a path-scoped entry in that
  repo's `.trivyignore` with a written reason, the same convention used for
  misconfiguration checks. Never lower the severity or turn the step advisory.
- **Only the tree is scanned on each PR, not the history.** Something committed
  and then deleted in the same PR passes the tree scan and is still public in
  the PR's commits. The history check is a periodic `gitleaks git` across all
  five repos. It was run on 2026-10-26: `platform` (363 commits) and `cloud`
  (72) are clean.
- **Topology and secret structure stay public**, as ADR-0013 accepted. Secret
  values stay encrypted at rest under SOPS
  ([ADR-0008](ADR-0008-sops-age.md)) or live in Vault.
- `build/`, which holds local admin and image-inventory kubeconfigs, is
  gitignored. The local scan finds a token there, and CI never sees it. Keep it
  that way.

## Alternatives considered

- **Private repos on GitHub Team** (the closed #219). Rejected for the costs in
  Context, and because privacy treats the symptom. A scanner that blocks
  catches the next leak whatever the repo's visibility.
- **Private on GitHub Free.** Rulesets are not enforced on private repos on
  Free, so unsigned, unreviewed commits could reach `main`. Rejected outright.
- **Rely on push protection alone.** It was already on, and the stream key got
  past it.
- **Gitleaks as the per-PR scanner instead of Trivy.** It is comparable at
  detection. Rejected only because Trivy is already pinned in every repo's CI,
  and a second scanner would be one more pin to keep current.
