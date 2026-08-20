# 03 — Kubernetes

Step 5–6 of [README's "Rebuild from nothing"](../README.md#rebuild-from-nothing):
`make deploy-cluster` then `make bootstrap-argocd`. Takes the three cluster
Pis from bare nodes to a kubeadm cluster with Cilium, default-deny
NetworkPolicy, and Argo CD reconciling everything else from git.

## Prerequisites

- Phase B complete: the runner stack is up on `1972-console-1` and registered
  to the org — [02-cicd.md](02-cicd.md)
- All four Pis converged to the hardened baseline (`make deploy-nodes`), so
  `kube_prereqs` (cgroups, swap masked) is already satisfied
- **The JWKS bucket exists in AWS** (`create_jwks_bucket = true` in
  `nineteenseventytwo-cloud`) — [06-aws-federation.md](06-aws-federation.md)
  step 1

> **One-way door.** `kubeadm init` fixes the API server's
> `--service-account-issuer` permanently. Building the cluster without it means
> pods can never federate to AWS, and the only fix is rebuilding the control
> plane. `kube_control_plane` asserts the issuer is set and well formed before
> it will run, and refuses to proceed if a running control plane disagrees with
> the inventory — but understand what it is protecting before you run step 1.
> The full sequence, including what to do in Cloudflare and when to enable the
> remaining AWS resources, is [06-aws-federation.md](06-aws-federation.md).

## 1. Build the cluster

```bash
make deploy-cluster            # CHECK=1 for a dry run
```

Runs `ansible/playbooks/30-cluster.yml`: `kube_prereqs` on all three nodes →
`kubeadm init` on `1972-master-1` (etcd encryption at rest, PSS admission) →
Cilium via Helm → join `worker-1`, `worker-2` → default-deny NetworkPolicy in
every namespace. Run it from your workstation the first time — the self-hosted
runner it could otherwise run from doesn't have a cluster to reach yet.

## 2. Fetch and store the kubeconfig

```bash
make kubeconfig                # writes ./build/kubeconfig
```

Store its contents as the org secret `KUBECONFIG`
(**Settings → Secrets and variables → Actions**) — `deploy-cluster.yml`'s
reconcile job needs it to nudge Argo CD after this point. Scope it; don't hand
out cluster-admin if you can avoid it — see the
[secret inventory](04-secrets.md#secret-inventory).

## 2a. Publish the OIDC discovery documents

```bash
make publish-oidc
```

Uploads the cluster's `openid-configuration` and `jwks` to the public bucket,
which is what lets AWS verify tokens the cluster's pods present. It checks the
issuer inside the document matches, then verifies the public URL — which fails
until the Cloudflare Worker is deployed. Both halves are step 3 and 4 of
[06-aws-federation.md](06-aws-federation.md); do them now, before Argo CD
brings up Vault and Longhorn.

## 3. Bootstrap Argo CD

```bash
make bootstrap-argocd
```

The one human-run `helm install`, ever. Installs Argo CD and applies
[`cluster/argocd/bootstrap/app-of-apps.yaml`](../cluster/argocd/bootstrap/app-of-apps.yaml),
which watches `cluster/argocd/applications/` and pulls in everything else by
sync wave — see [Reference](#argo-cd-sync-waves) below.

## 4. Wait for sync

```bash
make argocd-sync-wait          # nudges Argo CD, blocks until platform is Synced/Healthy
```

Argo polls every 3 minutes on its own; the lab has no inbound internet path
(same reason cert-manager uses DNS-01), so webhooks aren't an option. Use this
target instead of waiting out the poll.

## 5. Capture the baseline

```bash
kubescape scan framework nsa --format json --output docs/baseline-nsa.json
```

Run against the **empty** hardened cluster, before any workload exists to
muddy it, and commit the result. A before/after pair across the Cilium and
default-deny work is worth more than either scan alone.

## Verify

- `make verify-irsa` — a pod can assume an AWS role with no credential
- `kubectl get nodes` — control plane + both workers `Ready`
- `kubectl -n argocd get applications` — everything `Synced`/`Healthy`
- `kubectl get networkpolicy -A` — default-deny present in every namespace

## Definition of done

Cluster reachable, Argo CD reconciling `cluster/` from `main`. From here,
changing the cluster is a PR against [`cluster/`](../cluster/) — there is no
more `kubectl apply` from a laptop, and that discipline is what makes the
cluster reproducible rather than merely documented.

---

## Reference

### CNI vs. service mesh

These two layers get conflated constantly:

| Layer | Job | Options |
|---|---|---|
| **CNI** | Pod IPs, routing, L3/L4 NetworkPolicy | Cilium, Flannel, Calico. **Istio is not in this list.** |
| **Service mesh** | Workload identity, mTLS, L7 policy, canary routing | Istio, Linkerd, Cilium Service Mesh |

Istio ships an "Istio CNI node agent", but it only handles traffic
redirection — it still needs a real CNI underneath. Cilium and Istio are
complementary, not alternatives.

**Cilium only; the mesh is deferred**
([ADR-0003](decisions/ADR-0003-cni-cilium-no-mesh.md)). Cilium already
provides what's actually needed: NetworkPolicy enforcement (Flannel never had
this), Hubble flow observability, and transparent node-to-node WireGuard
encryption. The trigger to revisit is concrete — **L7 policy, per-workload
mTLS identity, or traffic shifting** — not before.

**kube-proxy replacement** is optional and has one gotcha: it needs
`k8sServiceHost`/`k8sServicePort` in the Helm values, because the API server
can't be reached through a Service that doesn't exist yet. `30-cluster.yml`
injects both from the inventory. If the build is fighting you, ship standard
mode (`cilium_kube_proxy_replacement: false`, the default here) and flip it
later — it's a supported migration.

### Argo CD sync waves

| Wave | What |
|---|---|
| −20 | Cilium (adopted; installed pre-Argo by the playbook) |
| 0–20 | MetalLB → ingress-nginx → cert-manager |
| 25 | pod-identity-webhook — before anything that federates to AWS |
| 30 | Longhorn |
| 40–50 | External Secrets → Vault |
| 60–80 | monitoring → ARC controller → scale sets |
| 90–95 | CRs that need the operators above, then `policy/` |
| 100 | `apps/` — one Application per app/environment, auto-discovered by an `ApplicationSet` |

Cilium is special: the cluster has no working datapath until it's installed,
and Argo CD runs *on* that datapath. So the playbook installs it and the
Application **adopts** the existing release, with the playbook-injected
values excluded from diffing so they don't fight each other.

### Sizing

Three RPi 5s at 2 GB. Everything in `cluster/` carries explicit requests and
limits, tight on purpose:

- `kubelet` reserves 256Mi system + 256Mi kube, with a 150Mi hard eviction
  threshold — that reserve is what leaves you able to SSH in and fix a node
  instead of watching it go unreachable.
- Longhorn runs 2 replicas, worker nodes only, rebuild concurrency 1 — a
  rebuild saturates the Pi's single 1 GbE link.
- kube-prometheus-stack is the heaviest thing here by a distance. Grafana,
  Alertmanager and Prometheus are all single-replica with 7-day retention.
- Hubble UI is off. Turn it on when you need to look at flows, not before.

### The shared-cluster boundary

This repo owns everything that touches the cluster — including, since
[ADR-0012](decisions/ADR-0012-platform-owns-app-workloads.md), the
application workloads themselves. App repos own their Dockerfile and CI, and
publish an image to GHCR; nothing about the cluster is theirs to touch — no
kubeconfig, no `kubectl`, no deploy step.

`platform` creates `eightbitsaxlounge-dev` and `-prod` with a ResourceQuota
and LimitRange in [`policy/tenants/`](../policy/tenants/) — the guardrails,
applied at sync wave 95. The Deployments, Services and Ingresses that
actually run live in [`apps/eightbitsaxlounge/`](../apps/) and reconcile at
wave 100, one sync-wave later, so a workload never lands before its quota
does. Bumping an app to a new image tag is a PR against the manifest here,
reviewed the same way as any other change to this repo.

This goes further than the usual "platform owns the namespace, app owns
what's in it" split — see ADR-0012 for why, and what it costs: an app
release is now two PRs in two repos (bump the version in the app repo, bump
the tag here) instead of one deploy step the app repo controls end to end.
