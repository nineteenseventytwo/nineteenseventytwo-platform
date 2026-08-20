# ADR-0004: Platform owns tenant namespaces, quotas and RBAC

**Status:** Superseded by [ADR-0012](ADR-0012-platform-owns-app-workloads.md)
**Date:** 2026-08-07

> Kept for the historical record: this was the boundary for about a day. The
> "consuming the kubeconfig they are handed" column below stopped being true
> once ADR-0012 moved application workloads into this repo too — there is no
> tenant kubeconfig anymore, and the per-tenant ServiceAccount/Role/RoleBinding
> this ADR introduced were removed from `policy/tenants/`. The ResourceQuota,
> LimitRange, PSS labels and namespace-creation argument below are all still
> current; only the RBAC-handoff mechanism changed.

## Context

Splitting infrastructure out of `eightbitsaxlounge` raises the question of where
the boundary sits. The original plan left namespace creation in the app repo
(`k8s-namespaces.yaml` creates `eightbitsaxlounge-dev` and `-prod` today).

Three nodes with 2 GB each means roughly 6 GB total, of which the platform
itself consumes about half.

## Decision

This repo owns everything cluster-scoped and every infra namespace, **plus**
tenant namespaces, their ResourceQuotas, LimitRanges, ServiceAccounts and Roles.

App repos own everything *inside* their namespaces and nothing else. Enforced
with RBAC, not convention.

| Owned by `platform` | Owned by app repos |
|---|---|
| CNI, MetalLB, ingress, cert-manager, Longhorn, monitoring, ARC, Vault, Argo CD | Their own namespaces and everything in them |
| Cluster-scoped RBAC, PSS namespace labels, default-deny policies | Their Deployments, Services, Ingresses, NetworkPolicy allow-pairs |
| Per-tenant ServiceAccount + namespaced Role + ResourceQuota + LimitRange | Consuming the kubeconfig they are handed |

## Consequences

- **The quota is a constraint, not a request.** If the app repo created its own
  namespace it would create it without a quota, and "please add a quota" is not
  enforcement.
- On 2 GB nodes this matters concretely: one runaway Deployment must not be able
  to evict Prometheus.
- The tenant kubeconfig is bound to a `Role` (namespaced), not a `ClusterRole`.
  It cannot list namespaces, cannot read another tenant's Secrets, and cannot
  edit its own ResourceQuota — a tenant that can edit its own quota does not
  have one.
- **Cost:** adding a tenant, or raising a quota, is now a PR against this repo.
  That is friction, and it is deliberate — but it does mean the platform repo is
  in the path of app-team changes it would otherwise not care about.
- Verification is part of the process:
  `kubectl auth can-i get secrets -n <other-tenant>` must return `no`. That
  check is in [`policy/tenants/README.md`](../../policy/tenants/README.md).

## Alternatives considered

**Leave namespace creation in the app repo.** Rejected for the reason above:
the quota and RBAC become unenforceable.

**Hierarchical Namespace Controller.** Solves this more elegantly at larger
scale. Rejected as another controller to run and debug on 2 GB nodes for two
tenants.
