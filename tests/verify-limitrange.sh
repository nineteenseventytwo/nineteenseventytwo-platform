#!/usr/bin/env bash
# Asserts every namespace that can run a pod has a LimitRange, or is on the
# explicit exemption list below. The direct analogue of
# verify-default-deny.sh, and it exists for the same reason: ADR-0016 decided
# that CPU limits come from the namespace LimitRange rather than from chart
# values, which makes "every namespace has one" load-bearing — and nothing
# checked it. A namespace with no LimitRange does not fail loudly. Its
# containers simply get no CPU limit at all, and the only symptom is silent
# CFS throttling never happening where it should, which is invisible until
# something else starves.
#
#   tests/verify-limitrange.sh
#
# Requires kubectl pointed at the cluster (./build/kubeconfig). Exit code is
# the count of uncovered, unexempted namespaces, or 125 if the cluster could
# not be reached at all — same enumeration guard, and the same reasoning, as
# verify-default-deny.sh.
set -uo pipefail

UNREACHABLE=125

# Two kinds of exemption, and they are checked differently.
#
# EXEMPT_DELIBERATE — runs pods, and is excluded on purpose. Skipped outright.
#   kube-system      excluded from LimitRange coverage by decision — see the
#                    header of policy/21-resource-quotas.yaml. Static pods and
#                    the CNI cannot be constrained by a namespace default
#                    without risking the control plane.
#
# EXEMPT_NO_PODS — exempt *because* no pod ever runs there, so there is nothing
# for a LimitRange to default. That is a claim about the cluster, not a
# preference, so this script asserts it rather than trusting it: if a pod ever
# appears in one of these, the exemption's premise has broken and it fails.
#   gateway          Cilium serves the Gateway's data plane from the
#                    `cilium-envoy` DaemonSet in kube-system, one per node.
#                    This namespace holds the Gateway object and its
#                    LoadBalancer Service and nothing else. Confirmed live
#                    2026-09-07: zero pods. If Cilium is ever reconfigured to
#                    provision a per-Gateway Deployment instead, this fails —
#                    which is the point.
#   cilium-secrets   holds TLS material for Cilium.
#   kube-node-lease  holds Lease objects.
#   kube-public      holds a ConfigMap.
EXEMPT_DELIBERATE=(
  kube-system
)

EXEMPT_NO_PODS=(
  gateway
  cilium-secrets
  kube-node-lease
  kube-public
)

in_list() {
  local ns="$1"; shift
  local e
  for e in "$@"; do [[ "$ns" == "$e" ]] && return 0; done
  return 1
}

FAIL=0
c_pass=$'\033[32m'; c_fail=$'\033[31m'; c_skip=$'\033[33m'; c_off=$'\033[0m'
[[ -t 1 ]] || { c_pass=""; c_fail=""; c_skip=""; c_off=""; }

# See verify-default-deny.sh for why this guard needs its own exit code: with
# no `set -e`, an unreachable cluster yields an empty list, iterates zero
# times, and exits 0 — indistinguishable from full coverage.
if ! NAMESPACES=$(kubectl get ns -o jsonpath='{.items[*].metadata.name}') \
   || [[ -z "${NAMESPACES// }" ]]; then
  echo "error: could not enumerate namespaces — is kubectl pointed at the cluster?" >&2
  echo "       (KUBECONFIG=${KUBECONFIG:-unset})" >&2
  exit "$UNREACHABLE"
fi

# Any LimitRange counts, not only one named default-limits — a namespace that
# has deliberately named its own differently is still covered. What is being
# asserted is that container defaults exist, not that they came from one file.
COVERED=$(kubectl get limitrange -A --no-headers 2>/dev/null | awk '{print $1}' | sort -u)

for ns in $NAMESPACES; do
  if in_list "$ns" "${EXEMPT_DELIBERATE[@]}"; then
    echo "${c_skip}SKIP${c_off}  $ns (exempt by decision)"
    continue
  fi

  if in_list "$ns" "${EXEMPT_NO_PODS[@]}"; then
    # The exemption is only valid while the premise holds. Checking it here is
    # what stops a name-based skip list from silently hiding a real gap the
    # day the cluster changes shape underneath it.
    pods=$(kubectl -n "$ns" get pods --no-headers 2>/dev/null | wc -l | tr -d ' ')
    if [[ "$pods" == "0" ]]; then
      echo "${c_skip}SKIP${c_off}  $ns (exempt: runs no pods — still true)"
    else
      echo "${c_fail}FAIL${c_off}  $ns is exempt on the grounds that no pod runs there, but $pods now do — the exemption is stale, not the namespace"
      FAIL=$((FAIL + 1))
    fi
    continue
  fi

  if grep -qx "$ns" <<<"$COVERED"; then
    echo "${c_pass}PASS${c_off}  $ns"
  else
    echo "${c_fail}FAIL${c_off}  $ns has no LimitRange and is not on the exemption list"
    FAIL=$((FAIL + 1))
  fi
done

exit "$FAIL"
