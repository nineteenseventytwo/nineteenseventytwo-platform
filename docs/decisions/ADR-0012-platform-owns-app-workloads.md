# ADR-0012: Platform repo owns application workloads, not just namespaces

**Status:** Accepted
**Date:** 2026-08-07
**Supersedes:** [ADR-0004](ADR-0004-platform-owns-tenant-namespaces.md) (the RBAC-handoff mechanism only — its ResourceQuota/LimitRange/PSS reasoning still stands)

## Context

ADR-0004 drew the boundary at the namespace: `platform` creates the namespace,
quota and a scoped ServiceAccount; the app repo's own pipeline reads the
resulting kubeconfig and deploys its Deployments, Services and Ingresses into
it. That is a common, reasonable split.

It was reconsidered before any app repo had built against it. The owner's
stated preference: all Kubernetes configuration should live in this repo, and
adding a namespace for a new app is something done here, not something an app
repo requests via a credential handoff.

## Decision

This repo owns the application workload manifests too, not only the namespace
they run in. [`apps/<name>/<env>/`](../../apps/) holds plain Kubernetes
manifests — Deployments, Services, Ingresses, ExternalSecrets, per-app
NetworkPolicy allow-pairs — and an `ApplicationSet` auto-discovers every
directory under `apps/*/*` and reconciles it as its own Argo CD Application.

App repos keep their Dockerfile, tests, and CI, and publish an image to GHCR.
They receive no cluster credential of any kind — no kubeconfig, no
`kubectl`, no deploy step. Releasing a new version means a PR here bumping the
`image:` tag.

`policy/tenants/` keeps owning the namespace, ResourceQuota, LimitRange and
default-deny NetworkPolicy — the guardrail/workload split from ADR-0004 is
preserved, it is just that both halves now live in this repo instead of being
split across two.

## Consequences

- **No tenant kubeconfig exists anymore.** The ServiceAccount/Role/RoleBinding
  `policy/tenants/eightbitsaxlounge.yaml` previously defined are gone. There is
  nothing to mint, nothing to rotate annually, nothing to put in Vault under
  `kv/tenants/*`, and nothing that can be the thing that leaks. That entire
  category of risk from ADR-0004 and the secret inventory is removed, not
  mitigated.
- **A release is two PRs in two repos**, not one deploy step the app repo
  controls end to end: bump the version in the app repo (tag the image, push
  to GHCR), then bump the tag in `apps/<name>/<env>/deployment.yaml` here. That
  second step is manual by design — see the alternatives below — and is real
  friction for a team that ships often.
- **Every application config for the whole lab is now reviewable in one place
  and one diff.** A change to eightbitsaxlounge's resource requests, ingress
  rules, or environment variables goes through the same PR review and the same
  Argo CD drift-correction as a change to Cilium's values. There is exactly one
  place `kubectl get deploy -A` behavior comes from.
- **This repo is now in the critical path of every app release**, where before
  it was only in the path of infrastructure changes. A merge freeze here (see
  the project's own conventions for what that looks like) now blocks app
  releases too, which it did not before.
- Auto-discovery via `ApplicationSet` means adding an app is genuinely "create
  a directory, add manifests, open a PR" — no Application YAML to hand-write,
  which was the concrete mechanism requested. `CreateNamespace=false` on the
  generated Applications keeps the "guardrails before workload" ordering from
  ADR-0004 intact: a namespace absent from `policy/tenants/` makes the
  generated Application fail to sync, loudly, rather than materialising an
  unquota'd namespace.
- The composer repo's services (`composer`, `llm-server`, `musicxml-tools`,
  `training`) are not yet represented under `apps/` — they were out of scope
  for this change and will follow the same pattern in
  [`apps/README.md`](../../apps/README.md) when migrated.

## Alternatives considered

**Argo CD Image Updater**, watching GHCR and auto-committing tag bumps here.
Would remove the manual second-PR step above. Rejected for now, not because it
is a bad idea, but because it is an additional controller with its own
registry-credential story that nobody asked for yet — it is a values-only
addition to the existing Argo CD release whenever the manual bump becomes
enough friction to justify it.

**Keep ADR-0004's split** (namespace here, workload + deploy credential in the
app repo). This is the more common pattern and has a real advantage: an app
team can ship without touching this repo. Rejected per the owner's explicit
preference — the value placed on "everything k8s-related lives in one
reviewable place" outweighs the app team's release-time friction, at this
team's size (one person, two app repos).

**A separate `apps` repo**, splitting infra from application GitOps config
while still keeping both out of the app repos themselves. Rejected as
unnecessary indirection for two applications; revisit if the number of
tenants grows enough that this repo's PR volume becomes a bottleneck.
