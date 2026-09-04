# ADR-0017: Which Kubescape NSA controls this cluster accepts as failing

**Status:** Accepted
**Date:** 2026-09-04

## Context

`docs/03-cluster.md` step 5 and `REBUILD.md` step 3.5 make a Kubescape NSA
scan a gate on every build, and the artefacts are committed
(`docs/builds/000N-baseline-nsa.json`, `000N-postinstall-nsa.json`). Build
0003 produced the first genuine before/after pair: **78/100 pre-install
against the empty hardened cluster, 73/100 post-install**.

That drop was logged as "not a bug — expected, workloads landing always costs
some score" and left there. Which is true, and is also the failure mode this
ADR exists to stop: a scan whose result is known in advance to be "some number
in the seventies, most of it not ours" is not a gate, it is a ritual. Nobody
can tell a new real finding from the standing eighteen, so nobody looks, and
the next real one lands in the noise.

Eighteen controls fail post-install. Triaging all of them, and then checking
the conclusions against the running cluster rather than only against the scan
file, turned up **four genuine findings and one substantial false positive** —
roughly the ratio that makes the exercise worth repeating and worth writing
down.

Two of the four are RBAC, and one of those is a *missing* grant, which a scan
looking for excess privilege cannot find by construction. Checking each grant
against its actual consumer is what found both.

## Decision

**Every failing control is classified below as fixed, accepted, or open, with
its reason. A scan is clean when its failures match this table. Anything not
in this table is a new finding and is triaged before the build closes.**

**No control is added to a Kubescape exceptions file.** A suppressed control
is indistinguishable from one nobody looked at; keeping the failure visible
and the reason next to it costs nothing and survives a Kubescape upgrade
renumbering its rules.

Worth knowing that Kubescape already applies its own: 45 rule results in
build 0003's post-install scan come back `passed` with
`subStatus: "w/exceptions"` across 13 controls, having failed the underlying
rule. That is the built-in list exempting the control plane and CoreDNS — it
is why `Deployment/kube-system/coredns` passes C-0270 despite having no CPU
limit, while `cilium` in the same namespace fails. So the honest statement is
not "nothing is suppressed here" but "this repo adds nothing to what the tool
already suppresses, and writes its own exceptions down in prose instead".

### Fixed

| Control | Factor | Was | What changed |
|---|---|---|---|
| C-0002 | 5 | 6 | `pods/exec` dropped from both `tenant-ci` Roles — granted on a guess, used by none of the four app-repo playbooks. The four remaining hits are not ours. [`policy/tenants/README.md`](../../policy/tenants/README.md#the-verb-set-vs-what-the-scripts-actually-do) |
| C-0034 | 6 | 38 | Two: `argocd-redis` ran as `serviceAccountName: default` with a mounted token and makes no API calls ([`cluster/README.md`](../../cluster/README.md#argocd-redis-mounts-a-token-it-never-uses)); Alertmanager's SA is bound to nothing and its `config-reloader` watches the filesystem, verified live ([`cluster/README.md`](../../cluster/README.md#alertmanager-holds-a-token-that-grants-nothing)) |

### Accepted — the scanner cannot see the mechanism

| Control | Factor | Failing | Why accepted |
|---|---|---|---|
| C-0270 Ensure CPU limits are set | 8 | 34 | Limits come from the namespace LimitRange at Pod admission; Kubescape scans controller templates. **Zero of the 34 are Pods.** 4 of 34 (kube-system) are real and deliberate. [ADR-0016](ADR-0016-cpu-limits-from-limitrange.md) |
| C-0271 Ensure memory limits are set | 8 | 13 | Same mechanism, same evidence — zero Pods among the failures. [ADR-0016](ADR-0016-cpu-limits-from-limitrange.md) |
| C-0012 Applications credentials in configuration files | 8 | 5 | All five verified false positives, by reading the flagged objects: `vault-config` holds the KMS *alias* for auto-unseal — the block whose entire purpose is that there is no credential (ADR-0005); `metallb-controller` has `METALLB_ML_SECRET_NAME`, an env var naming a Secret, not holding one; `cilium-config`'s matches are feature flags and file *paths* (`hubble-tls-key-file`); `argocd-cm`'s are config toggles, and `exec.enabled` renders `"false"` (verified by `helm template`); `kube-public/cluster-info` is the CA bundle kubeadm publishes unauthenticated **by design** so joining nodes can verify the API server before they can authenticate to it. |
| C-0068 PSP enabled | 1 | 1 | PodSecurityPolicy was removed in Kubernetes 1.25. This cluster uses Pod Security Admission — `enforce: baseline` cluster-wide via the apiserver admission config, raised per namespace in `policy/00-namespaces.yaml`. The control tests for a resource that no longer exists. |

### Accepted — structural, and the component would not work otherwise

These are the CNI, the CSI driver, the L2 load-balancer and the node
exporter. Their privileges are what they are for, and none is configurable
away without removing the component.

| Control | Factor | Failing | Who |
|---|---|---|---|
| C-0057 Privileged container | 8 | 7 | cilium, cilium-envoy, longhorn csi-plugin / engine-image / instance-manager |
| C-0041 HostNetwork access | 7 | 5 | cilium ×3, metallb-speaker, node-exporter |
| C-0046 Insecure capabilities | 7 | 4 | cilium ×2 (NET_ADMIN/SYS_MODULE for eBPF), longhorn-csi-plugin, metallb-speaker |
| C-0038 Host PID/IPC privileges | 7 | 1 | node-exporter — the one control that newly appeared post-install, and reading host process state is the job |
| C-0044 Container hostPort | 4 | 4 | cilium ×3, kube-apiserver static pod |
| C-0013 Non-root containers | 6 | 31 | Upstream chart defaults across cilium, longhorn, cert-manager, external-secrets, argocd, metallb, ARC |
| C-0016 Allow privilege escalation | 6 | 17 | Same set |
| C-0017 Immutable container filesystem | 3 | 19 | Same set |
| C-0055 Linux hardening | 4 | 19 | Same set — seccomp/AppArmor/SELinux profiles the charts do not set |
| C-0035 Administrative Roles | 6 | 3 | `kubeadm:cluster-admins`, Argo CD's application-controller (it applies arbitrary manifests — that is the product), Longhorn's support-bundle SA |
| C-0034 Automatic mapping of service account | 6 | 36 remaining | Controllers that call the API server and need their own token. `pod-identity-webhook` is ours and already carries a `checkov.io/skip1` annotation saying so. |

### Accepted — already a documented deliberate exclusion

| Control | Factor | Failing | Where the reasoning already lives |
|---|---|---|---|
| C-0054 Cluster internal networking | 4 | 3 | `cilium-secrets`, `gateway`, `node-exporter-system` — three of the six namespaces named in [`policy/10-default-deny.yaml`](../../policy/10-default-deny.yaml)'s header, each with its own reason. `gateway` runs no pods (a `podSelector: {}` policy there is inert, not protective); `node-exporter-system` is entirely `hostNetwork: true`, confirmed live 2026-08-23 that NetworkPolicy does not govern it at all. |
| C-0030 Ingress and Egress blocked | 6 | 5 | kube-system (cilium ×3, hubble-relay) and node-exporter-system — the same exemption list. kube-system holds CoreDNS and the CNI; a wrong rule there takes the cluster down before anything could fix it. |

### Open

| Item | Why it is not closed |
|---|---|
| `deployments/scale` for `tenant-ci` | `chat-set-environment.yaml` needs it; granting it would let a tenant credential fight Argo CD's reconciliation loop. The script should delete the Pod instead. Belongs to WP-5. [`policy/tenants/README.md`](../../policy/tenants/README.md#deploymentsscale-is-needed-and-is-still-deliberately-not-granted) |
| No check asserts LimitRange coverage | Coverage is complete today — verified live, the only namespaces without one run no workloads — but a new namespace added without one silently opts out of the mechanism [ADR-0016](ADR-0016-cpu-limits-from-limitrange.md) depends on. `tests/verify-default-deny.sh` does exactly this job for NetworkPolicy and exists because the same gap was open there. |

## Consequences

- **The next scan is diffable.** "73/100, eighteen controls" stops being the
  result. The result is whether the failure set matches this table.
- **This table has to be maintained or it rots into the thing it replaced.**
  It is pinned to build 0003's post-install scan. A chart upgrade that adds a
  `seccompProfile`, or a Kubescape release that renumbers a control, moves
  rows. The build log's evidence checklist is where that gets noticed.
- **Most of the score is not reachable and saying so is the point.** Eleven of
  the eighteen controls are the CNI and the CSI driver being a CNI and a CSI
  driver. A cluster that scored 95 here would be one that had removed
  Longhorn, not one that was safer.
- **Two of the four real findings were RBAC, and one was a missing grant.**
  Checking a grant against its actual consumer is what found both; neither
  would have surfaced from reading the scan alone.
- **The cluster settled what the scan file could not.** Both C-0034 fixes
  and ADR-0016's central claim were confirmed against `build/kubeconfig`,
  and one of them (Alertmanager) had been parked as "candidate, needs a live
  check" for exactly that reason. A triage done only against a committed JSON
  artefact would have shipped three of these and left the fourth open.

## Alternatives considered

**Suppress the accepted controls via a Kubescape exceptions file so the score
reads clean.** Rejected. The score is not the artefact — the failure set is.
A machine-readable exceptions file also silently stops applying when a
control is renumbered upstream, and nothing would say so; a table someone has
to edit fails loudly, in review.

**Fix the fixable upstream findings by overriding `securityContext` in every
chart's values.** Rejected as a class, not case by case. Overriding
`runAsNonRoot`/`readOnlyRootFilesystem` on components whose own charts do not
set them means guessing at what each container writes where, discovered one
CrashLoopBackOff at a time, on a cluster where Longhorn going down means
every PVC-backed pod goes with it. Where a chart offers a supported key and
the component's needs are known — `redis.automountServiceAccountToken` — that
is a fix and was taken.

**Do nothing; keep logging the pre/post gap as expected.** Rejected: that is
the status quo this ADR exists to end. Build 0003 logged C-0270 as a headline
mover in the 78→73 drop; it turns out to be an artefact of where the scanner
looks, and nobody would have found that without going through the controls
one at a time.
