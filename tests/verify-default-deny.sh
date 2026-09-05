#!/usr/bin/env bash
# Asserts every namespace either has a default-deny-all NetworkPolicy or is on
# the explicit exemption list documented at the top of
# policy/10-default-deny.yaml. Exists because "default-deny in every
# namespace" was a README sentence for months without anything checking it —
# 14 of 19 namespaces had it, 5 silently didn't, and three of those five held
# the cluster's own secrets material. A new namespace landing here uncovered
# should fail CI, not wait to be noticed.
#
#   tests/verify-default-deny.sh
#
# Requires kubectl pointed at the cluster (./build/kubeconfig). Exit code is
# the count of uncovered, unexempted namespaces, or 125 if the cluster could
# not be reached at all — see the enumeration guard below for why that case
# needs its own code rather than falling out as 0.
set -uo pipefail

UNREACHABLE=125

# Keep this list in sync with the exemption comment at the top of
# policy/10-default-deny.yaml — that comment explains *why* each one is here;
# this is just the enforceable list.
EXEMPT=(
  kube-system
  cilium-secrets
  kube-node-lease
  kube-public
  gateway
  node-exporter-system
)

is_exempt() {
  local ns="$1" e
  for e in "${EXEMPT[@]}"; do [[ "$ns" == "$e" ]] && return 0; done
  return 1
}

FAIL=0
c_pass=$'\033[32m'; c_fail=$'\033[31m'; c_skip=$'\033[33m'; c_off=$'\033[0m'
[[ -t 1 ]] || { c_pass=""; c_fail=""; c_skip=""; c_off=""; }

# Without this guard the script reports success when it never ran. There is no
# `set -e`, so a kubectl that cannot reach the cluster leaves $NAMESPACES
# empty, the loop below iterates zero times, FAIL stays 0, and it exits 0 —
# indistinguishable from "every namespace is covered". REBUILD.md step 4.5
# gates on that exit code, so an unreachable cluster passed the gate.
# Confirmed 2026-09-05: with KUBECONFIG unset, `make verify-default-deny`
# printed "connection to the server localhost:8080 was refused" and still
# exited 0. A cluster always has at least kube-system, so empty means the
# enumeration failed, never that there is nothing to check.
if ! NAMESPACES=$(kubectl get ns -o jsonpath='{.items[*].metadata.name}') \
   || [[ -z "${NAMESPACES// }" ]]; then
  echo "error: could not enumerate namespaces — is kubectl pointed at the cluster?" >&2
  echo "       (KUBECONFIG=${KUBECONFIG:-unset})" >&2
  exit "$UNREACHABLE"
fi

COVERED=$(kubectl get networkpolicy -A --no-headers 2>/dev/null \
  | awk '$2=="default-deny-all"{print $1}')

for ns in $NAMESPACES; do
  if is_exempt "$ns"; then
    echo "${c_skip}SKIP${c_off}  $ns (exempt)"
    continue
  fi
  if grep -qx "$ns" <<<"$COVERED"; then
    echo "${c_pass}PASS${c_off}  $ns"
  else
    echo "${c_fail}FAIL${c_off}  $ns has no default-deny-all NetworkPolicy and is not on the exemption list"
    FAIL=$((FAIL + 1))
  fi
done

exit "$FAIL"
