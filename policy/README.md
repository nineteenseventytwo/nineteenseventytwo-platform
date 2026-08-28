# policy/

Cluster-scoped guardrails. Applied once by `ansible/playbooks/30-cluster.yml`
(so the cluster is never briefly open) and reconciled thereafter by the
`platform-policy` Argo CD Application (so it stays that way).

| File | What it enforces |
|---|---|
| `00-namespaces.yaml` | Infra namespaces with their Pod Security Standards labels |
| `10-default-deny.yaml` | Default-deny ingress + egress in every namespace that carries workloads, with the DNS exception. Exemptions (CNI/DNS-critical namespaces, and hostNetwork-only ones where standard NetworkPolicy isn't enforced) are documented at the top of the file. |
| `20-limitrange-default.yaml` | A default request/limit so an unspecified pod cannot claim a whole node |
| `30-prowler.yaml` | The `security` namespace's ServiceAccount + CronJob, scheduled Prowler scans against the whole AWS account |
| `tenants/*.yaml` | Per-app namespace + ResourceQuota + LimitRange + ServiceAccount + Role |

## Why default-deny goes in first

Retrofitting default-deny onto a running cluster means discovering which flows
you broke one incident at a time. Applying it to an empty cluster means every
allow-pair is added deliberately, by the team that needs it, in a PR.

Cilium enforces this. Flannel could not, which is the practical reason for the
CNI swap — see [ADR-0003](../docs/decisions/ADR-0003-cni-cilium-no-mesh.md).

## The tenant contract

`platform` creates the namespace, quota and RBAC. The app repo gets a
kubeconfig for a ServiceAccount that can act **only** in its own namespace, and
its pipeline uses that. It cannot create namespaces, cannot touch cluster-scoped
resources, and cannot exceed its quota. `bootstrap/tenant-kubeconfig/generate.sh`
turns the ServiceAccount into that kubeconfig and publishes it to Vault.

ResourceQuota matters more than it sounds on 2 GB nodes: one runaway Deployment
should not be able to evict Prometheus.

Adding a tenant is a PR here. Copy `tenants/eightbitsaxlounge.yaml`, change the
names, and follow the kubeconfig instructions at the bottom of that file.
