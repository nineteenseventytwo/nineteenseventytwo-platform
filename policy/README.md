# policy/

Cluster-scoped guardrails. Applied once by `ansible/playbooks/30-cluster.yml`
(so the cluster is never briefly open) and reconciled thereafter by the
`platform-policy` Argo CD Application (so it stays that way).

| File | What it enforces |
|---|---|
| `00-namespaces.yaml` | Infra namespaces with their Pod Security Standards labels |
| `10-default-deny.yaml` | Default-deny ingress + egress in every namespace that carries workloads, with the DNS exception. Exemptions (CNI/DNS-critical namespaces, and hostNetwork-only ones where standard NetworkPolicy isn't enforced) are documented at the top of the file. |
| `20-limitrange-default.yaml` | A default request/limit so an unspecified pod cannot claim a whole node. This is also where every CPU limit in the cluster comes from — see [ADR-0016](../docs/decisions/ADR-0016-cpu-limits-from-limitrange.md) |
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

---

# Findings

Prowler ran here as a CronJob in the `security` namespace until 2026-10-26.
A scan peaks at 650-840Mi of real memory, which took a 4GB worker NotReady, and
it audits AWS, not the cluster - so it moved to a daily GitHub Actions job in
`nineteenseventytwo-cloud` (`.github/workflows/prowler.yml`), with its mutelist
and the hard-won notes on its flags (`prowler/README.md` there). The `security`
namespace stays for `41-ci-image-inventory.yaml`.

## Observing pod DNS

`12-egress-observe.yaml` exists because the nodes' egress proxy
(`egress_proxy_enabled`) covers apt, docker and containerd image pulls, not
pods. Pod traffic is masqueraded to the node IP and leaves straight through
OPNsense, so a Squid log never sees it, and pods are where the `0.0.0.0/0`
egress rules in `10-default-deny.yaml` are.

**What it widens.** A namespace that allowed DNS only for some of its pods
(dash, cloudflared) now allows it for all of them. Every pod in those
namespaces needs DNS anyway.

**Why three namespaces are excluded.** `default` and `security` are
default-deny with no DNS allow at all, on purpose. `kube-system`'s CoreDNS
forwards upstream on its own rule, not through kube-dns, so there is nothing
to observe, and keeping the proxy out of that namespace keeps a DNS-proxy
fault away from CoreDNS and hubble-relay.

**It only worked from 2026-10-27.** Hubble's metrics port (9965) was allowed
in the pod-network policy but not in the nodes' ufw, so every scrape was
dropped for the first two days (#254).

## Grafana could not reach its datasources for two months

`allow-grafana-datasources-egress` and `allow-datasources-from-grafana` in
`10-default-deny.yaml` were added on 2026-10-27. Before that, nothing allowed
Grafana's server-side queries to Prometheus or Alertmanager:
`default-deny-all` had covered the `monitoring` namespace's egress since
2026-08-23, and every Prometheus-backed panel had timed out since then
(`dial tcp 10.99.53.71:9090: i/o timeout`). The dashboard sidecar kept
working, because it talks to the API server, which `allow-monitoring-apiserver`
covers. So dashboards appeared while every panel on them was empty. Nobody
noticed until the Findings dashboard was the first thing anyone opened.
