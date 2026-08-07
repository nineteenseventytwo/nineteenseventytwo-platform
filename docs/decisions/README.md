# Decision records

One file per decision that would otherwise be re-litigated in six months. The
useful part is the **Consequences** section — including the ones that are
inconvenient.

| ADR | Decision | Status |
|---|---|---|
| [0001](ADR-0001-github-org.md) | Create a `nineteenseventytwo` GitHub organisation | Accepted |
| [0002](ADR-0002-private-repo.md) | The platform repo is private | Accepted |
| [0003](ADR-0003-cni-cilium-no-mesh.md) | Cilium as CNI; defer the service mesh | Accepted |
| [0004](ADR-0004-platform-owns-tenant-namespaces.md) | Platform owns tenant namespaces, quotas and RBAC | Superseded by [0012](ADR-0012-platform-owns-app-workloads.md) |
| [0005](ADR-0005-argocd-and-vault-kms.md) | Argo CD from the start; Vault with KMS auto-unseal | Accepted |
| [0006](ADR-0006-runner-docker-socket.md) | Mount the docker socket in bootstrap runners | Accepted, with a stated exit |
| [0007](ADR-0007-console-outside-cluster.md) | `1972-console` stays out of the cluster | Accepted |
| [0008](ADR-0008-sops-age.md) | SOPS+age; retire ansible-vault | Accepted |
| [0009](ADR-0009-dhcp-authority.md) | Kea reservations are authoritative for addressing | Accepted |
| [0010](ADR-0010-fork-pr-self-hosted-runners.md) | Route `pull_request` jobs to hosted runners | Accepted |
| [0011](ADR-0011-arm64-only.md) | arm64 only; the GPU node is out of scope for now | Accepted |
| [0012](ADR-0012-platform-owns-app-workloads.md) | Platform repo owns application workloads, not just namespaces | Accepted |

## Template

```markdown
# ADR-NNNN: Title

**Status:** Proposed | Accepted | Superseded by ADR-NNNN
**Date:** YYYY-MM-DD

## Context
What forced a decision. Include the constraints that are not obvious.

## Decision
What was decided, in one paragraph.

## Consequences
What this makes easy, what it makes hard, and what it commits us to.
Include the ones you would rather not write down.

## Alternatives considered
What was rejected and why. "Not now" is a valid reason if the trigger to
revisit is written down.
```
