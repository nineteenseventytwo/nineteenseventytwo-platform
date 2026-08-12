# 03 — Kubernetes

## Build order

```
kube_prereqs (all 3 nodes)
  → kubeadm init on 1972-master-1     [etcd encryption at rest, PSS admission]
  → Cilium                            [helm; kube-proxy replacement optional]
  → join worker-1, worker-2
  → default-deny NetworkPolicy in every namespace
  → Argo CD                           [make bootstrap-argocd]
  → everything else, reconciled from cluster/
```

The first five steps are `ansible/playbooks/30-cluster.yml` (`make
deploy-cluster`). After `make bootstrap-argocd`, changing the cluster is a PR
against [`cluster/`](../cluster/) — there is no `kubectl apply` from a laptop,
and that discipline is what makes the cluster reproducible rather than merely
documented.

`1972-console-1` stays out of the cluster. It builds the cluster, so putting it in
creates a circular dependency — a rebuild would need the cluster already
running to run the runner that rebuilds it. All four boards are the same
hardware now, so that circular-dependency argument is the whole reason, not a
resource constraint. [ADR-0007](decisions/ADR-0007-console-outside-cluster.md).

## CNI vs service mesh

These two layers get conflated constantly, so being precise about them is worth
a paragraph:

| Layer | Job | Options |
|---|---|---|
| **CNI** | Pod IPs, routing, L3/L4 NetworkPolicy | Cilium, Flannel, Calico. **Istio is not in this list.** |
| **Service mesh** | Workload identity, mTLS, L7 policy, canary routing | Istio, Linkerd, Cilium Service Mesh |

Istio ships something called the "Istio CNI node agent", but it only handles
traffic redirection — it still needs a real CNI underneath. Cilium and Istio
are complementary, not alternatives.

**Cilium only; the mesh is deferred**
([ADR-0003](decisions/ADR-0003-cni-cilium-no-mesh.md)). Cilium already provides
what is actually needed next: NetworkPolicy enforcement (which Flannel never
had), Hubble flow observability, and transparent node-to-node WireGuard
encryption — encryption in transit without a mesh.

The trigger to revisit is concrete: **L7 policy, per-workload mTLS identity, or
traffic shifting.** Not before.

### kube-proxy replacement

Optional, and it has one gotcha: it needs `k8sServiceHost`/`k8sServicePort` in
the Helm values, because the API server cannot be reached through a Service
that does not exist yet. `30-cluster.yml` injects both from the inventory. If
the cluster build is already fighting you, ship standard mode
(`cilium_kube_proxy_replacement: false`, the default here) and flip it later —
it is a supported migration.

## Argo CD

One human-run `helm install`, ever:

```bash
make bootstrap-argocd
```

That installs Argo CD and applies
[`cluster/argocd/bootstrap/app-of-apps.yaml`](../cluster/argocd/bootstrap/app-of-apps.yaml),
which watches `cluster/argocd/applications/` and pulls in everything else.

Sync waves order the dependencies:

| Wave | What |
|---|---|
| −20 | Cilium (adopted; installed pre-Argo by the playbook) |
| 0–30 | MetalLB → ingress-nginx → cert-manager → Longhorn |
| 40–50 | External Secrets → Vault |
| 60–80 | monitoring → ARC controller → scale sets |
| 90–95 | CRs that need the operators above, then `policy/` |
| 100 | `apps/` — one Application per app/environment, auto-discovered by an `ApplicationSet` |

Cilium is special: the cluster has no working datapath until it is installed,
and Argo CD runs *on* that datapath. So the playbook installs it and the
Application **adopts** the existing release, with the playbook-injected values
excluded from diffing so they do not fight.

Argo polls every 3 minutes. The lab has no inbound internet path (which is also
why cert-manager uses DNS-01), so webhooks are not an option; `make argocd-sync`
forces a reconcile when you cannot wait, and `deploy-cluster.yml` does the same
then blocks until `Synced/Healthy`.

## Sizing

Three RPi 5s at 2 GB. Everything in `cluster/` carries explicit requests and
limits, and the numbers are tight on purpose:

- `kubelet` reserves 256Mi system + 256Mi kube, with a 150Mi hard eviction
  threshold. That reserve is what leaves you able to SSH in and fix a node
  instead of watching it become unreachable.
- Longhorn runs 2 replicas, worker nodes only, with rebuild concurrency of 1 —
  a rebuild saturates the Pi's single 1 GbE link.
- kube-prometheus-stack is the heaviest thing here by a distance. Grafana,
  Alertmanager and Prometheus are all single-replica with 7-day retention.
- Hubble UI is off. Turn it on when you need to look at flows, not before.

## Baseline artefact

Run Kubescape against the **empty** hardened cluster and commit the result,
before any workload exists to muddy it:

```bash
kubescape scan framework nsa --format json --output docs/baseline-nsa.json
```

A before/after pair across the Cilium and default-deny work is worth more than
either scan alone.

## The shared-cluster boundary

This repo owns everything that touches the cluster — including, since
[ADR-0012](decisions/ADR-0012-platform-owns-app-workloads.md), the application
workloads themselves. App repos own their Dockerfile and CI, and publish an
image to GHCR. Nothing about the cluster is theirs to touch: no kubeconfig, no
`kubectl`, no deploy step.

`platform` creates `eightbitsaxlounge-dev` and `-prod` with a ResourceQuota and
LimitRange in [`policy/tenants/`](../policy/tenants/) — the guardrails, applied
at sync wave 95. The Deployments, Services and Ingresses that actually run
inside those namespaces live in [`apps/eightbitsaxlounge/`](../apps/) and
reconcile at wave 100, one sync-wave later, so a workload never lands before
its quota does. Bumping an app to a new image tag is a PR against the manifest
here, reviewed the same way any other change to this repo is.

This goes further than the usual "platform owns the namespace, app owns what's
in it" split — see ADR-0012 for why, and what it costs: an app release is now
two PRs in two repos (bump the version in the app repo, bump the tag here)
instead of one deploy step the app repo controls end to end.
