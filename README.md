# nineteenseventytwo-platform

Infrastructure for the `nineteenseventytwo` lab: four Raspberry Pis on VLAN 20, a
three-node kubeadm cluster, and the CI/CD that builds and reconciles both.

This repo answers one question: **how do I rebuild everything from nothing?**

All Kubernetes configuration lives here, including application workloads —
`nineteenseventytwo-eightbitsaxlounge` and `nineteenseventytwo-composer` own
their Dockerfiles and build pipelines and publish images to GHCR; what
actually runs in the cluster is defined in [`apps/`](apps/) and reconciled by
Argo CD. See [the boundary rule](#the-boundary-rule).

---

## Hardware

| Host | Model | RAM | Address | Role |
|---|---|---|---|---|
| `1972-console-1` | RPi 5 | 2 GB | `192.168.20.201` | Bootstrap node. Break-glass runner. **Not** in the cluster. |
| `1972-master-1` | RPi 5 | 2 GB | `192.168.20.202` | Control plane |
| `1972-worker-1` | RPi 5 | 2 GB | `192.168.20.203` | Worker (Longhorn replica) |
| `1972-worker-2` | RPi 5 | 2 GB | `192.168.20.204` | Worker (Longhorn replica) |

All four boards are now identical hardware. `1972-console-1` still stays out of
the cluster deliberately — it builds the cluster, so putting it in creates a
circular dependency: a rebuild would need the cluster already running to run
the runner that rebuilds it. That argument holds regardless of hardware. See
[ADR-0007](docs/decisions/ADR-0007-console-outside-cluster.md).

The x86 GPU PC is **not** in scope for this repo yet — see
[ADR-0011](docs/decisions/ADR-0011-arm64-only.md).

---

## Rebuild from nothing

Each step is a `make` target, and CI calls the same targets you do.

```bash
# 0. One-time, on your workstation
make deps                     # check podman/docker, sops, age are present
                               # (RUNNER_LOCAL=1 also checks ansible, kubectl, helm)

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
#    The AWS JWKS bucket must exist first, and kubeadm bakes the OIDC issuer
#    in permanently — docs/06-aws-federation.md steps 0-1.
make deploy-cluster           # kubeadm + Cilium + join workers + default-deny

# 5a. Publish the cluster's OIDC discovery documents, then wire up the
#     Cloudflare Worker so AWS can reach them (docs/06-aws-federation.md 3-5)
make publish-oidc

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
policy/      default-deny NetworkPolicies, PSS labels, per-tenant quota (guardrails).
apps/        application workload manifests, reconciled by the same Argo CD instance.
tests/       network and node validation, re-runnable after any firewall change.
docs/        guides and decision records.
```

## The boundary rule

This repo owns everything: cluster-scoped infra, every namespace, and every
workload manifest that runs in the cluster. App repos own their own
Dockerfile, tests, and build pipeline — the artefact that lands in GHCR — and
nothing about the cluster.

| Owned here | Owned by app repos |
|---|---|
| CNI, MetalLB, ingress, cert-manager, Longhorn, monitoring, ARC, Vault, Argo CD | Build, test, and push the image to GHCR |
| Namespaces, PSS labels, ResourceQuota, LimitRange, default-deny policy ([`policy/tenants/`](policy/tenants/)) | `CHANGELOG.md` / `version.txt` for their own image |
| Deployments, Services, Ingresses, ExternalSecrets — everything that actually runs ([`apps/`](apps/)) | Nothing cluster-side. No kubeconfig, no `kubectl`, no deploy step. |

Adding an app, or a namespace for one, is a PR here — see
[`policy/tenants/README.md`](policy/tenants/README.md) and
[`apps/README.md`](apps/README.md). No cluster-admin credential, or any
credential at all, is ever handed to an app repo. See
[ADR-0012](docs/decisions/ADR-0012-platform-owns-app-workloads.md) for why this
goes further than the usual "platform owns the namespace, app owns what's in
it" split.

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
| [06-aws-federation.md](docs/06-aws-federation.md) | IRSA on kubeadm: the OIDC issuer, the JWKS bucket, Cloudflare, and the rollout order |
| [07-runbooks.md](docs/07-runbooks.md) | Documented fixes for recurring incidents, starting with what an unclean reboot leaves behind |
| [decisions/](docs/decisions/) | ADRs |
| [plan/](docs/plan/) | The originating plan this repo was built from |
