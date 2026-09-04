# ADR-0016: CPU limits come from the namespace LimitRange, not from chart values

**Status:** Accepted
**Date:** 2026-09-04

## Context

Every `resources:` block in `cluster/*/values.yaml` sets a memory limit and no
CPU limit:

```yaml
resources:
  requests: {cpu: 50m, memory: 128Mi}
  limits: {memory: 384Mi}
```

That shape holds for every `resources:` block in the repo — eleven of the
twelve values files carry one, `kubelet-csr-approver` sets none at all — and
has never been written down anywhere, which makes it look like an omission
repeated a dozen times rather than a choice made once. It is a choice, and Kubescape is what
forced it to be stated: the NSA framework's **C-0270, "Ensure CPU limits are
set"** is the single highest-weighted control this cluster fails (scoreFactor
8, 34 failing resources) and was named in build 0003's log as one of the two
headline movers in the 78→73 pre/post drop.

The two facts that make the decision:

**CPU and memory limits do different things.** Exceeding a memory limit gets
the container OOMKilled — so memory limits have to be sized per component
against what that component actually does, and this repo has paid for that
several times over (the Argo CD application-controller at 512Mi then 1Gi then
2Gi, Grafana at 256Mi then 512Mi, Prowler at 1Gi then 2Gi). Exceeding a CPU
limit gets the container CFS-throttled: no crash, no event, just latency,
during exactly the bursts — startup, a full Argo CD sync, a Longhorn rebuild
— when the work is most worth doing. A too-low memory limit is loud. A
too-low CPU limit is silent.

**`policy/20-limitrange-default.yaml` already sets one.** Fourteen namespaces
carry a LimitRange whose `default:` block is, by definition, the default
*limit* applied to any container that does not set its own. Sized per
namespace from live usage. So the containers in this cluster do have CPU
limits — they are just applied at Pod admission rather than written into a
Deployment template.

## Decision

**Memory limits are set explicitly per component in chart values. CPU limits
come from the namespace LimitRange, and a component sets its own only when it
has a specific reason to differ from the namespace default.**

Two manifests do set a CPU limit, both deliberately and both consistent with
this: `policy/30-prowler.yaml` (`cpu: "1"` against the `security` namespace's
`200m` default — a bounded batch CronJob that should be allowed to finish
fast) and `cluster/pod-identity-webhook/20-deployment.yaml` (`cpu: 100m`,
matching its namespace default exactly, in a fully self-contained
hand-written manifest).

## Consequences

- **Kubescape C-0270 will never pass, and its failure count is not a
  measure of anything.** Kubescape scans controller specs — Deployment,
  DaemonSet, StatefulSet — as stored in the API. LimitRange defaults are
  injected by the admission controller into Pods, so they are invisible to
  a scan of the templates. The scanner is looking at the layer the mechanism
  does not operate on. Same applies to **C-0271** (memory limits).

  Measured directly against the running cluster (`build/kubeconfig`,
  2026-09-04), which settles it without relying on any inference from the
  scan file: **62 of 77 running containers carry a CPU limit, and all 15
  that do not are in `kube-system`.** The templates of the workloads
  Kubescape fails — `argocd-server`, `monitoring-grafana`, `longhorn-ui`,
  `metallb-controller`, `cert-manager` — set no `resources.limits.cpu` at
  all, and their Pods run with one anyway. The Longhorn `instance-manager`
  Pods carry `cpu: 500m`, precisely the `longhorn-system` LimitRange's
  `default.cpu`, which Longhorn's own chart never sets.
- **Fifteen containers genuinely run with no CPU limit, all in
  `kube-system`**, which `policy/21-resource-quotas.yaml` deliberately
  excludes from LimitRange and quota coverage: the three cilium-agents,
  three cilium-envoys, cilium-operator, hubble-relay, both CoreDNS replicas,
  and the four control-plane static pods (etcd, apiserver, scheduler,
  controller-manager). Only four of those surface as C-0270 failures — the
  cilium ones — because **Kubescape's own built-in exception list already
  exempts the control plane and CoreDNS** (they come back `passed` with
  `subStatus: "w/exceptions"`, having failed the underlying
  `resources-cpu-limits` rule). That exclusion is the existing kube-system
  decision's consequence, not a new one, and it is the correct trade for the
  namespace holding the CNI and DNS.
- **LimitRange coverage is currently complete, and nothing enforces that it
  stays so.** Live check: the only namespaces without a LimitRange are
  `cilium-secrets`, `gateway`, `kube-node-lease`, `kube-public` and
  `kube-system` — the first four run no workloads at all and the fifth is the
  deliberate exclusion above. So every workload-carrying namespace is
  covered today. But a new namespace added without one silently opts out of
  this ADR's entire mechanism, and no check would say so.
  `tests/verify-default-deny.sh` does exactly this job for NetworkPolicy
  coverage and exists because "every namespace has default-deny" was true of
  the README and not the cluster; the same gap is open for LimitRange.
- **Per-component CPU tuning costs an extra step.** Changing one component's
  CPU ceiling means either adding an explicit limit to its values (fine, and
  the two existing exceptions show the shape) or moving the whole namespace's
  default. The second is the wrong lever for one noisy pod.

## Alternatives considered

**Set CPU limits everywhere to make C-0270 pass.** Rejected. It would add
CFS throttling to every component in the cluster — on 2 GB Pis, to the Argo
CD controller that already needed 2Gi of memory headroom for a single
full-fleet sync, and to Longhorn replica rebuilds — in exchange for a
scanner score, on nodes where CPU is the resource least likely to be the
binding constraint. The `guaranteedInstanceManagerCPU` incident recorded in
`policy/20-limitrange-default.yaml`'s own header is a preview of the failure
mode: a CPU limit that interacts badly with a request computed elsewhere took
storage down cluster-wide, and no volume attached until it was raised.

**Drop the LimitRange defaults and require every component to set its own
limits.** Rejected: it makes the guarantee opt-in, which is the thing the
LimitRange exists to prevent. A pod with no limits is invisible to the
scheduler's accounting, and on these nodes that is the difference between one
unhappy pod and an unresponsive node.

**Suppress C-0270 in the scan configuration rather than writing this down.**
Rejected on the grounds that a suppressed control is indistinguishable from
one nobody looked at. The exception register in
[ADR-0017](ADR-0017-kubescape-accepted-controls.md) keeps the failure visible
in every scan and keeps the reason next to it.
