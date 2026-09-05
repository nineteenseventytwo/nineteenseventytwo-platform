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
        ├── gateway-api-crds     wave -30  (before Cilium's own Gateway API controller can start)
        ├── cilium               wave -20  (installed pre-Argo by 30-cluster.yml, adopted here)
        ├── metallb               wave 0
        ├── cert-manager         wave 20
        ├── gateway              wave 22   (the shared Gateway — ADR-0015 — every app attaches an HTTPRoute to it)
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

---

# Findings

Things learned against the running cluster that would be expensive to re-learn.
Each one was an inline comment in the file it belongs to until the pass before
build 0002 — see [docs/conventions.md](../docs/conventions.md) for why they live
here now.

## Longhorn

### preUpgradeChecker

`preUpgradeChecker.jobEnabled: false`. The chart's own `values.yaml` says to
disable this under Argo CD or any other GitOps tool, and means it. Native Helm
skips a pre-upgrade hook on a genuine first install — nothing to upgrade yet.
Argo CD has no install-vs-upgrade distinction and runs every hook
unconditionally on the very first sync. The hook Job's own pod spec references
`longhorn-service-account`, a regular (non-hook) chart resource that does not
exist yet on a first sync, so it fails every attempt with `serviceaccount
longhorn-service-account not found` — and since Argo CD blocks the rest of the
sync wave on hook success, nothing else in the chart, *including that
ServiceAccount*, ever gets applied either.

Confirmed live: deleting the stuck Job just gets an identical one recreated,
failing identically, every time.

### The S3 backup credential secret is not a credential

`backupTargetCredentialSecret` cannot be empty. Confirmed live: Longhorn's
backup-target client refuses an S3 target outright — `could not access s3
without credential secret` — even once the pod-identity-webhook has injected
`AWS_ROLE_ARN` / `AWS_WEB_IDENTITY_TOKEN_FILE` into the manager pod's own env.
That env is not enough on its own.

[`secret-backup-credential.yaml`](longhorn/secret-backup-credential.yaml) carries
a single `AWS_IAM_ROLE_ARN` key, which is what tells this specific client path to
use IRSA ([longhorn/longhorn#1526](https://github.com/longhorn/longhorn/issues/1526))
instead of demanding a real key pair. It is not a secret — the same role ARN is
committed in `values.yaml` and in `nineteenseventytwo-cloud`'s trust policy.

The bucket, its lifecycle rules and the role live in `nineteenseventytwo-cloud`
(`live/aws/platform-prod`). Backups are the one line item in the cost model with
no natural ceiling — the bucket expires them at 90 days, but a schedule left on
hourly will still find that out for you.

### IRSA annotation placement

The chart puts the `eks.amazonaws.com/role-arn` annotation on
`longhorn-service-account`, which is exactly the subject the
`cluster-longhorn-backup` role's trust policy pins. It also lands on
`longhorn-ui-service-account`, which is harmless: the annotation is a *request*,
and the trust policy on the AWS side decides.

## kubelet-csr-approver

### Why it is installed at all

kubeadm auto-approves the kubelet *client* CSR used for apiserver→kubelet auth,
but not `kubernetes.io/kubelet-serving` — the certificate kubelet's own HTTPS
endpoint presents to `kubectl logs`/`exec`/`attach` and to anything scraping
kubelet metrics over TLS.

`serverTLSBootstrap: true` (`ansible/roles/kube_control_plane`) means kubelet
requests one, but with nothing to approve it a Pending CSR just sits there —
which is exactly what a backlog of them did before this was installed, cleared by
hand once as a stopgap. This closes the gap so the *next* rotation (kubeadm's
certificates are valid one year) does not repeat it silently.

### bypassDnsResolution must be true here

Confirmed live: bare node hostnames (`1972-master-1`, etc.) do not resolve
anywhere on this network — only specific service FQDNs have OPNsense Unbound
overrides ([docs/01-network-validation.md](../docs/01-network-validation.md)),
never the nodes themselves. Left `false`, the approver's own DNS-resolution
check would fail every single CSR, defeating the point of installing it.

## Cilium

### kube-proxy replacement is what unblocks Gateway API

Migrated from standard mode (kube-proxy alongside Cilium) on 2026-09-01. Beyond
the performance argument, Cilium's Gateway API controller **refuses to start
without it** — confirmed live in PR #92, where the GatewayClass sat in
`Unknown` / "Waiting for controller" indefinitely and the operator logged
`Gateway API support requires kube-proxy-replacement enabled`.

The ansible-injected `k8sServiceHost` / `k8sServicePort` (not in `values.yaml` —
`ansible/playbooks/30-cluster.yml` supplies them from the inventory) are what let
the agent reach the API server directly instead of through a Service that does
not exist yet. `cilium_kube_proxy_replacement` in the inventory now only matters
for a from-scratch rebuild starting in the same mode.

### Gateway API needs its CRDs a wave earlier

`gatewayAPI.enabled: true` requires the Gateway API CRDs to exist before the
agent starts — hence
[`argocd/applications/00-gateway-api-crds.yaml`](argocd/applications/00-gateway-api-crds.yaml)
at sync wave −30, ahead of Cilium's own −20. `gatewayClass.create` defaults to
`auto`, which creates the GatewayClass once the CRDs are present; left as the
default rather than duplicating that logic in values.

This replaced ingress-nginx, archived upstream on 2026-03-24 with no further CVE
patches ([ADR-0015](../docs/decisions/ADR-0015-cilium-gateway-api.md)). Cilium is
the CNI everything already runs on and already ships the `cilium-envoy`
DaemonSet this depends on — no new component.

## The shared Gateway

### One Gateway, one IP

Every app attaches an HTTPRoute to the one Gateway, the same way every app
previously shared the one ingress-nginx controller. Per-app Gateways would mean
per-app LoadBalancer IPs, each needing its own OPNsense DNS override.

`cert-manager.io/cluster-issuer` works on a Gateway exactly as it does on an
Ingress (cert-manager 1.15+, `config.gatewayAPI.enabled: true` in
[`cert-manager/values.yaml`](cert-manager/values.yaml)) — one Certificate per
unique `certificateRefs` name, DNS names taken from each listener's own
`hostname`. Cilium's secret-sync (`secretsNamespace.sync`, on by default) mirrors
each issued Secret into `cilium-secrets` for Envoy to read; nothing does that by
hand.

Listeners share port 443 and are separated by SNI — standard Gateway API listener
merging, the same way ingress-nginx served every host off one IP:port. Each app's
HTTPRoute attaches by hostname match alone; no `sectionName` is needed while the
hostnames do not overlap.

### Pinning the LoadBalancer IP goes through an annotation, not spec.addresses

`infrastructure.annotations: metallb.io/loadBalancerIPs` pins the address, for the
same reason ingress-nginx's `controller.service.loadBalancerIP` did: so the
Unbound host overrides on OPNsense
([docs/01-network-validation.md](../docs/01-network-validation.md)) do not need
updating every time the Service is recreated.

Cilium's own `spec.addresses` field needs LB-IPAM, which this cluster does not
use — MetalLB does the allocation, and `l2announcements.enabled: false` in
Cilium's values is deliberate. `infrastructure.annotations` is what actually
reaches the Service MetalLB is watching. `192.168.20.241` was already the address
allocated on first sync; pinning just stops it from ever being anything else.

## Argo CD

### argocd-redis mounts a token it never uses

Kubescape **C-0034, "Automatic mapping of service account"** fails on 38
resources in this cluster. Thirty-seven are controllers that genuinely need
their own token to do their job — the argocd application/applicationset
controllers, cert-manager and its cainjector/webhook, external-secrets, the
Cilium operator, every Longhorn CSI sidecar, the prometheus-operator, ARC's
controller, and `pod-identity-webhook` (whose own manifest carries a
`checkov.io/skip1` annotation saying exactly this). The control does not
distinguish between them.

`argocd-redis` is the one that is not like the others. The rendered
Deployment runs as `serviceAccountName: default` with
`automountServiceAccountToken: true`, and Redis is a cache — it makes no
API-server calls at all. So the pod carries a mounted, valid token *for the
namespace's default ServiceAccount*, with nothing that ever reads it. That is
worth removing on its own merits, independent of the score.

`redis.automountServiceAccountToken: false` in `argocd/values.yaml` is scoped
to the redis Deployment only. The separate `redis-secret-init` Job has its
own ServiceAccount and Role — it writes the Redis auth Secret through the API
and does need a token — and that key does not touch it. Verified by rendering
the chart before and after: the diff is one line, on the redis Deployment,
out of 33,759 rendered lines.

Argo CD bootstraps itself via `make bootstrap-argocd` rather than through a
GitOps Application, so this change needs that command re-run by hand to reach
the cluster — same as any other `argocd/values.yaml` change.

## Monitoring

### Alertmanager holds a token that grants nothing

The second of the two genuine Kubescape C-0034 findings, and the one that
needed a live cluster to settle rather than an argument. Alertmanager was
listed in ADR-0017 as a candidate rather than a fix precisely because its
`config-reloader` sidecar's behaviour was unverified — the sidecar is the part
that could plausibly have needed the API.

Three checks, against the running cluster (`build/kubeconfig`, 2026-09-04):

- **The ServiceAccount is bound to nothing.** Sweeping every ClusterRoleBinding
  and RoleBinding in the cluster for `monitoring-kube-prometheus-alertmanager`
  as a subject returns no rows, and
  `kubectl auth can-i --list --as=system:serviceaccount:monitoring:monitoring-kube-prometheus-alertmanager`
  shows only the `system:discovery` / `system:basic-user` grants every
  authenticated identity gets — `/healthz`, `/version`, self-subject reviews.
  `get pods`, `list secrets` and `get configmaps` are all `no`.
- **`config-reloader` watches the filesystem, not the API.** Its actual args
  are `--watched-dir=/etc/alertmanager/config`,
  `--watched-dir=/etc/alertmanager/secrets/slack-alerts` and
  `--reload-url=http://127.0.0.1:9093/-/reload`. It reloads on inotify and
  POSTs to localhost. The Secret reaches it as a kubelet-refreshed volume
  mount, which is the operator's design, not an API call it makes itself.
- **Alertmanager itself reads `--config.file`**, a path, same as everything
  else in its argv.

So the projected token is mounted, authenticates successfully, and can do
nothing with that. `alertmanager.alertmanagerSpec.automountServiceAccountToken:
false` in `monitoring/values.yaml`.

Note the difference from the argocd-redis case, which needed no cluster to
decide: there the reasoning was "Redis is a cache, it has no API client at
all". Here the pod does have a component that legitimately might have needed
the API, and "probably not" was not good enough to land on a cluster where
Alertmanager is the only thing that tells anyone something is broken.

### bootstrap-argocd has to be re-runnable, not just runnable

`make bootstrap-argocd` is the only path by which a `cluster/argocd/values.yaml`
change reaches the cluster — Argo CD's own Helm release is not GitOps-managed,
so nothing else applies it. Until 2026-09-04 that path was broken on any
cluster where Argo CD had been running for more than one sync, which is every
cluster that is not being built from scratch right now.

The target's first step server-side-applies
`cluster/gateway-api-crds/standard-install.yaml`. Ten CRDs go through fine.
The two objects that do not are the Gateway API's own admission policy, which
ships in that same file:

```
Apply failed with 1 conflict: conflict with "argocd-controller": .spec.matchConstraints
Apply failed with 1 conflict: conflict with "argocd-controller": .spec.matchResources
```

- `ValidatingAdmissionPolicy/safe-upgrades.gateway.networking.k8s.io` →
  `.spec.matchConstraints`
- `ValidatingAdmissionPolicyBinding/safe-upgrades.gateway.networking.k8s.io` →
  `.spec.matchResources`

Both are owned by the `argocd-controller` field manager, because the
`gateway-api-crds` Application syncs the identical file with
`ServerSideApply=true`. This is the adoption the comment above the target
already describes working as intended — the target just never accounted for
what adoption does to its own next run. `make` exits 1 before `helm upgrade`
runs at all, so the values change silently does not land and the failure looks
like it is about CRDs rather than about Argo CD.

`--force-conflicts` is the right answer here, not a workaround, and the
ownership history proves it rather than merely arguing it. On this cluster:

```
kubectl            2026-09-04T06:56:33Z   # bootstrap applied it
argocd-controller  2026-09-04T06:58:37Z   # first sync took the fields
```

Argo CD has already taken these exact fields from `kubectl` once, unprompted,
two minutes after bootstrap. Forcing hands them back for the duration of one
apply; the `gateway-api-crds` Application (`selfHeal: true`,
`ServerSideApply=true`) takes them again on its next sync, exactly as it did
the first time. Both managers are applying the same file from the same commit,
so there is no divergent value for either to win — the conflict is about
bookkeeping, not content.

### A kube-prometheus-stack sync takes ~18 minutes, and looks wedged the whole time

Measured 2026-09-04: an Alertmanager values change synced from
`startedAt: 19:56:38Z` to `finishedAt: 20:14:35Z` — **17m57s**, `phase:
Succeeded`, no retries, nothing wrong. On three 2 GB Pis, rendering and
diffing this chart is simply that slow.

What makes it expensive is not the wait, it is that every signal during the
wait says something is broken:

```
phase:     Running
message:   <none>
resources: 0            # in .status.operationState.syncResult, for ~18 minutes
```

`.status.sync.status` reads **`Synced`** and `.status.sync.revision` moves to
the new commit almost immediately, while the live objects still hold their old
values and the application-controller logs this every two minutes:

```
"Skipping auto-sync: another operation is in progress" application=monitoring
```

All of that is normal for an in-flight sync. Nothing logs at `level=error`.
Checking `kubectl get application` alone will tell you the change landed
roughly fifteen minutes before it does.

**Do not restart the application-controller on this evidence alone.** Builds
0002 and 0003 both recorded genuinely wedged operations with a near-identical
surface — an orphaned sync after an OOMKill, and a `platform-policy` sync with
no apply activity — and the fix there was a controller restart. The difference
is only visible in time: a wedged operation never reaches `Succeeded`, a slow
one does. Read `.status.operationState.startedAt` first and give this chart
twenty minutes before concluding anything:

```bash
kubectl -n argocd get application monitoring \
  -o jsonpath='{.status.operationState.phase} {.status.operationState.startedAt}{"\n"}'
```

If it is still `Running` well past that, then it is the build-0003 case and a
controller restart is the documented fix — `argocd.argoproj.io/refresh=hard`
and an `.operation` reset were both established there not to clear it.
