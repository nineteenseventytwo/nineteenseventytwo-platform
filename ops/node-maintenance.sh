#!/usr/bin/env bash
# Sheds the workloads a planned node reboot can do without, and puts them
# back afterwards. Used by "Applying node updates" in docs/07-runbooks.md.
#
#   ops/node-maintenance.sh on      # scale the shed list to 0, record counts
#   ops/node-maintenance.sh check   # attached Longhorn volumes all healthy?
#   ops/node-maintenance.sh off     # restore the recorded counts
#
# Why it exists: draining one worker puts everything on the other, and a
# 4 GB worker cannot carry the whole cluster. On 2026-10-31 worker-2 took
# worker-1's pods, ran out of memory (no swap), and its kubelet stopped
# renewing its lease: NotReady, with the only current copy of seven Longhorn
# volumes on it. Nothing was OOM-killed; the node just thrashed.
#
# Shedding first keeps the survivor inside its memory, and it also detaches
# the tenants' volumes before any node goes down. A detached volume takes no
# writes, so its replicas stay identical however many nodes reboot while it
# is shed. That is why one `on` covers the whole round of nodes rather than
# one node at a time.
#
# Argo CD's application controller goes first. Every app syncs with
# selfHeal, so with the controller up it would scale everything back within
# three minutes. It comes back last in `off`, after the recorded counts are
# restored, so it finds nothing to change.
#
# Each scaled object carries its previous replica count in the annotation
# below. `off` restores from that, not from git: chat's count is
# deliberately not in git (see apps/eightbitsaxlounge/README.md), so only
# the live value says which environment's chat was the active one.
#
# Requires kubectl pointed at the cluster (./build/kubeconfig).
set -euo pipefail

ANNOTATION=platform.nineteenseventytwo/maintenance-replicas

# Order matters: the Argo CD controller must be first.
#   namespace/kind/name  one object
#   namespace            every Deployment and StatefulSet in it
#
# Kept running on purpose: the CNI, CoreDNS, Longhorn, MetalLB, cert-manager,
# external-secrets, pod-identity-webhook, kubelet-csr-approver, Vault,
# cloudflared, Falco's DaemonSet, and Prometheus/Alertmanager. Prometheus
# also belongs to the prometheus-operator, which would scale it straight
# back up.
SHED=(
  argocd/statefulset/argocd-application-controller
  argocd
  eightbitsaxlounge-dev
  eightbitsaxlounge-prod
  composer-dev
  dash
  findings
  falco/deployment/falco-falcosidekick
  monitoring/deployment/monitoring-grafana
)

die() { echo "node-maintenance: $*" >&2; exit 1; }

# Expands SHED into one "namespace kind/name" line per object, in order,
# without repeats.
targets() {
  local entry ns kind name
  for entry in "${SHED[@]}"; do
    IFS=/ read -r ns kind name <<<"$entry"
    if [[ -n "$name" ]]; then
      echo "$ns $kind/$name"
    else
      kubectl -n "$ns" get deployments,statefulsets -o name |
        sed "s|^|$ns |; s|\.apps/|/|"
    fi
  done | awk '!seen[$0]++'
}

# Attached volumes must be healthy. Detached ones report robustness
# "unknown", which is expected; they are listed but do not fail the check.
check() {
  local vols bad
  vols=$(kubectl -n longhorn-system get volumes.longhorn.io --no-headers \
    -o custom-columns=NAME:.metadata.name,STATE:.status.state,ROBUSTNESS:.status.robustness,NODE:.status.currentNodeID,PVC:.status.kubernetesStatus.pvcName)
  echo "$vols"
  bad=$(awk '$2 != "detached" && $3 != "healthy"' <<<"$vols")
  if [[ -n "$bad" ]]; then
    echo >&2
    echo "not ready: these volumes are attached but not healthy" >&2
    echo "$bad" >&2
    return 1
  fi
  echo "ok: every attached volume is healthy"
}

on() {
  check >/dev/null || die "fix the volumes above before shedding (run: $0 check)"

  local ns obj current
  while read -r ns obj; do
    # Already shed (a re-run after a partial failure): keep the first count.
    if [[ -n "$(kubectl -n "$ns" get "$obj" -o jsonpath="{.metadata.annotations.${ANNOTATION//./\\.}}")" ]]; then
      echo "already shed: $ns $obj"
      continue
    fi
    current=$(kubectl -n "$ns" get "$obj" -o jsonpath='{.spec.replicas}')
    kubectl -n "$ns" annotate "$obj" "$ANNOTATION=${current:-1}" >/dev/null
    kubectl -n "$ns" scale "$obj" --replicas=0 >/dev/null
    echo "shed: $ns $obj (was ${current:-1})"
  done < <(targets)

  # By pod, not by .status.replicas: a terminating pod no longer counts
  # there but still holds its volume, and the point is detached volumes.
  echo "waiting for the shed pods to stop..."
  local selector
  while read -r ns obj; do
    # shellcheck disable=SC2016 # $k and $v are go-template, not shell
    selector=$(kubectl -n "$ns" get "$obj" \
      -o go-template='{{range $k, $v := .spec.selector.matchLabels}}{{$k}}={{$v}},{{end}}')
    kubectl -n "$ns" wait pod -l "${selector%,}" --for=delete --timeout=5m >/dev/null ||
      die "$ns $obj still has pods after 5m"
  done < <(targets)

  echo
  check
}

off() {
  local ns obj recorded controller=""
  # Everything with a recorded count, the Argo CD controller held back
  # until the end.
  while read -r ns obj; do
    recorded=$(kubectl -n "$ns" get "$obj" -o jsonpath="{.metadata.annotations.${ANNOTATION//./\\.}}")
    [[ -n "$recorded" ]] || continue
    if [[ "$ns $obj" == "argocd statefulset/argocd-application-controller" ]]; then
      controller=$recorded
      continue
    fi
    kubectl -n "$ns" scale "$obj" --replicas="$recorded" >/dev/null
    kubectl -n "$ns" annotate "$obj" "$ANNOTATION-" >/dev/null
    echo "restored: $ns $obj to $recorded"
  done < <(targets)

  if [[ -n "$controller" ]]; then
    kubectl -n argocd scale statefulset/argocd-application-controller --replicas="$controller" >/dev/null
    kubectl -n argocd annotate statefulset/argocd-application-controller "$ANNOTATION-" >/dev/null
    echo "restored: argocd statefulset/argocd-application-controller to $controller"
  fi
}

case "${1:-}" in
  on) on ;;
  off) off ;;
  check) check ;;
  *) die "usage: $0 on|off|check" ;;
esac
