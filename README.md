# nineteenseventytwo-platform

Infrastructure for the `nineteenseventytwo` lab: four Raspberry Pis on VLAN 20, a
three-node kubeadm cluster, and the CI/CD that builds and reconciles both.

This repo answers one question: **how do I rebuild everything from nothing?**

Application repos (`nineteenseventytwo-eightbitsaxlounge`,
`nineteenseventytwo-composer`) own their own namespaces and nothing else. See
[the boundary rule](#the-boundary-rule).

---

## Hardware

| Host | Model | RAM | Address | Role |
|---|---|---|---|---|
| `1972-console` | RPi 4 | 1 GB | `192.168.20.201` | Bootstrap node. Break-glass runner. **Not** in the cluster. |
| `1972-master-1` | RPi 5 | 2 GB | `192.168.20.202` | Control plane |
| `1972-worker-1` | RPi 5 | 2 GB | `192.168.20.203` | Worker (Longhorn replica) |
| `1972-worker-2` | RPi 5 | 2 GB | `192.168.20.204` | Worker (Longhorn replica) |

`1972-console` stays out of the cluster deliberately — it builds the cluster, so
putting it in creates a circular dependency, and 1 GB will not take a kubelet
plus a runner. See [ADR-0007](docs/decisions/ADR-0007-console-outside-cluster.md).

The x86 GPU PC is **not** in scope for this repo yet — see
[ADR-0011](docs/decisions/ADR-0011-arm64-only.md).

---

## Rebuild from nothing

Each step is a `make` target, and CI calls the same targets you do.

```bash
# 0. One-time, on your workstation
make deps                     # check ansible, sops, age, kubectl, helm are present

# 1. Image the SSDs (per host, by hand, once)
make bootstrap-render HOST=1972-master-1
#    -> writes build/1972-master-1/{user-data,network-config}
#    -> copy both onto the boot partition, boot the Pi

# 2. Prove the network before installing anything
make test-network             # runs tests/network-check.sh against VLAN 20

# 3. Converge every node to the hardened baseline
make deploy-nodes

# 4. Stand up the CI/CD host (compose runner stack on console)
make deploy-cicd

# 5. Build the cluster
make deploy-cluster           # kubeadm + Cilium + join workers + default-deny

# 6. Hand the cluster to Argo CD; everything in cluster/ reconciles from git
make bootstrap-argocd
```

After step 6 there is no more `helm install` from a laptop. Argo CD reconciles
`cluster/` from `main`. See [docs/03-cluster.md](docs/03-cluster.md).

---

## Layout

```
bootstrap/   pre-Ansible. Run by hand, exactly once per node.
ansible/     node configuration. Roles + inventory + playbooks.
images/      ansible-runner and gha-runner container images.
cluster/     everything after `kubeadm init`. Helm values, reconciled by Argo CD.
policy/      default-deny NetworkPolicies, PSS labels, per-tenant quota + RBAC.
tests/       network and node validation, re-runnable after any firewall change.
docs/        guides and decision records.
```

## The boundary rule

This repo owns everything cluster-scoped and every infra namespace. App repos own
their own namespaces and nothing else — enforced with RBAC, not convention.

| Owned here | Owned by app repos |
|---|---|
| CNI, MetalLB, ingress, cert-manager, Longhorn, monitoring, ARC, Vault, Argo CD | Their own namespaces and everything in them |
| Cluster-scoped RBAC, PSS namespace labels, default-deny policies | Their Deployments, Services, Ingresses, NetworkPolicy allow-pairs |
| Per-tenant ServiceAccount + namespaced Role + ResourceQuota + LimitRange | Consuming the kubeconfig they are handed |

Tenant definitions live in [policy/tenants/](policy/tenants/). Adding an app repo
to the cluster is a PR here, not a cluster-admin credential handed out.

## Secrets

Nothing sensitive is committed in plaintext. Config secrets are SOPS+age
(`.sops.yaml` sets the recipients); cluster workload secrets are Vault +
External Secrets Operator. The full inventory — every secret, where it lives,
what it can reach, rotation cadence, blast radius — is
[docs/04-secrets.md](docs/04-secrets.md).

## Docs

| | |
|---|---|
| [00-bootstrap.md](docs/00-bootstrap.md) | Imaging and first boot |
| [01-network-validation.md](docs/01-network-validation.md) | VLAN 20 test matrix and the OPNsense rules it implies |
| [02-cicd.md](docs/02-cicd.md) | Runners, images, workflows |
| [03-cluster.md](docs/03-cluster.md) | kubeadm, Cilium, addons, Argo CD |
| [04-secrets.md](docs/04-secrets.md) | Secret inventory and rotation |
| [decisions/](docs/decisions/) | ADRs |
| [plan/](docs/plan/) | The originating plan this repo was built from |
