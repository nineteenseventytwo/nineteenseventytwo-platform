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

# Why each one is exempt:
#   kube-system      deliberately excluded from LimitRange coverage — see the
#                    header of policy/21-resource-quotas.yaml. Static pods and
#                    the CNI cannot be constrained by a namespace default
#                    without risking the control plane.
#   kube-node-lease  holds Lease objects only. No pod ever runs here.
#   kube-public      holds a ConfigMap only. No pod ever runs here.
#   cilium-secrets   holds TLS material for Cilium. No pod ever runs here.
EXEMPT=(
  kube-system
  kube-node-lease
  kube-public
  cilium-secrets
)

is_exempt() {
  local ns="$1" e
  for e in "${EXEMPT[@]}"; do [[ "$ns" == "$e" ]] && return 0; done
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
  if is_exempt "$ns"; then
    echo "${c_skip}SKIP${c_off}  $ns (exempt)"
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
