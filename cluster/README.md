# cluster/

Everything after `kubeadm init`. Each directory is one Helm release plus the
manifests that release needs, and **Argo CD reconciles all of it from `main`**.

There is exactly one `helm install` executed by a human, ever: `make
bootstrap-argocd`. After that, changing the cluster means merging a PR here.
No `kubectl apply` from a laptop — that is the discipline that makes the
cluster reproducible rather than merely documented.

## Reconciliation

```
cluster/argocd/bootstrap/app-of-apps.yaml
  └── watches cluster/argocd/applications/*.yaml
        ├── cilium               wave -20  (installed pre-Argo by 30-cluster.yml, adopted here)
        ├── metallb               wave 0
        ├── ingress-nginx        wave 10
        ├── cert-manager         wave 20
        ├── longhorn             wave 30
        ├── external-secrets     wave 40
        ├── vault                wave 50
        ├── monitoring           wave 60
        ├── arc (controller + scale sets)  wave 70-80
        ├── platform-manifests   wave 90   (MetalLB pool, Issuers, ClusterSecretStore — CRs that need the charts above)
        ├── platform-policy      wave 95   (../policy/ — namespaces, quota, default-deny)
        └── apps (ApplicationSet) wave 100 (../apps/*/* — one Application per app/env, auto-discovered)
```

Sync waves order the dependencies — cert-manager's CRDs must exist before an
Issuer, ESO's before a ClusterSecretStore, Longhorn wants MetalLB up so its UI
is reachable when you go looking for it, and no application workload
reconciles until its namespace's quota and default-deny policy are in place.
`apps/` and its ApplicationSet are documented in [`apps/README.md`](../apps/README.md) —
see [ADR-0012](../docs/decisions/ADR-0012-platform-owns-app-workloads.md) for
why application workloads live in this repo at all.

## Version pinning

Every `Application` pins `targetRevision` to an exact chart version, and every
`values.yaml` carries a `# chart:` comment with the same string. The comment is
what `make bootstrap-argocd` greps for, and it means the version is visible in
the file you are editing rather than only in the Application next to it.

**Verify these against the current charts before the first apply** — they were
pinned when this repo was written:

```bash
helm repo update && helm search repo <repo>/<chart> --versions | head
```

## The bootstrap ordering problem

Argo CD manages Vault; Vault holds the secrets Argo CD's managed apps need; ESO
projects them. That is a cycle only if you try to resolve it all at once. The
order that works:

1. SOPS+age holds the bootstrap secrets (Tier 0) — no cluster required.
2. Argo CD installs ESO and Vault. Vault auto-unseals from AWS KMS, so nothing
   waits on a human at 11pm.
3. Vault is populated from the SOPS values, once.
4. Everything else reads from Vault via `ExternalSecret`.

Full detail in [docs/04-secrets.md](../docs/04-secrets.md).
