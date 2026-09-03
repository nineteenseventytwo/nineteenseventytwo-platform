# Documentation conventions

Where an explanation lives, and how long it is allowed to be.

This repo is unusually well commented, and that is the problem it is solving as
much as the one it has: the rationale is real and hard-won, but a lot of it sits
inline in `values.yaml` files where the config it explains has been pushed
fifteen lines down the page. The goal is not fewer explanations. It is the same
explanations, findable, with the config still readable.

## The four places

| Tier | Lives in | Holds | Length |
|---|---|---|---|
| **Decision** | `docs/decisions/ADR-NNNN-*.md` | A choice that would otherwise be re-litigated, with its alternatives | A page |
| **Directory** | `<dir>/README.md` | How the directory fits together, plus **findings** — things learned live that would be expensively re-learned | Sections |
| **File header** | Top of the file, above the first config key | Why this file exists, and the few facts that govern the whole file | **≤ 12 lines** |
| **Inline** | Above or trailing a single key | What this value does, or why it is not the default | **1 line** |

## Choosing between them

Ask: *if someone changed this value, what breaks, and where would they go
looking?*

- Breaks the architecture, and someone will propose the alternative again → **ADR**
- Breaks something in a different file in this directory → **directory README**
- Breaks something else in this file → **file header**
- Breaks only this setting → **inline one-liner**

## The five-line rule

**An inline comment longer than about five lines is a finding, not a comment.**

Findings are the most valuable prose in the repo — "confirmed live", "tried this
and it did the opposite", "the chart's own docs are wrong here". They are also
the ones that get buried, because they are long and they sit next to a
two-character value.

Move the finding to the directory README under a **Findings** heading, and leave
a one-line pointer:

```yaml
# Argo CD runs this hook on a first sync; see ../README.md#preupgradechecker
preUpgradeChecker:
  jobEnabled: false
```

Nothing is lost. The value is readable. The finding is somewhere a person
browsing the directory will actually meet it, rather than only someone who
happens to open that one file.

## File headers

Every `values.yaml` already starts with the pinned chart and repo. That block is
the header; keep it at the top and keep it short:

```yaml
---
# chart: longhorn 1.12.1
# repo:  https://charts.longhorn.io
#
# Two replicas across the two workers, IRSA for S3 backups.
# Findings: ../README.md#longhorn
```

Three things and no more: what it is, the one-sentence shape of the file, and
where the long-form lives. If the header needs a fourth paragraph, that
paragraph belongs in the README.

## What does not go in a comment at all

**Change history.** `# Bumped 2026-09-02 for the crypto/x509 CVEs` is git's job,
and a comment that accumulates dates decays into a changelog nobody trims.

The exception, and it matters: keep it when the *reason still constrains the
value*. "Pinned to 3.6.14-0 because kubeadm's default version map at this minor
does not include it" governs what the next person may do; "bumped on Tuesday"
does not. Write the constraint, drop the date.

## One-liners are encouraged

The convention is not "fewer comments". A trailing one-liner on a value whose
purpose is not obvious from its name is exactly right and should stay:

```yaml
reclaimPolicy: Retain   # a deleted PVC should not silently destroy data
replicaSoftAntiAffinity: false      # never put both replicas on one node
```

These cost one line, explain one thing, and do not displace the config. Add more
of them, not fewer.

## Applying it to an existing file

1. Read the comment. Is it a decision, a finding, a file-level fact, or a value
   note?
2. Anything over five lines: move it to the directory README, verbatim — do not
   paraphrase a finding, the specifics are the value.
3. Leave a pointer with the section anchor.
4. Check the file still reads top-to-bottom as configuration.

Convergence is expected to be gradual: files get converted when they are touched
for another reason. The exception was the pass before build 0002, which took the
densest files deliberately.
