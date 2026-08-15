#!/usr/bin/env bash
# VLAN 20 validation matrix. Run this from a Pi on a VLAN 20 access port
# (switch ports 5-8, PVID 20) BEFORE installing anything, and again after every
# firewall change. The whole point of codifying it is that re-running is cheap.
#
#   tests/network-check.sh            # all tests
#   tests/network-check.sh 5 6        # only tests 5 and 6
#
# Exit code is the number of failed tests, so CI can gate on it.
set -uo pipefail

GATEWAY="${LAB_GATEWAY:-192.168.20.1}"
SUBNET_PREFIX="${LAB_SUBNET_PREFIX:-192.168.20.}"
WORKSTATION_HOST="${WORKSTATION_HOST:-192.168.10.50}"
MASTER_HOST="${MASTER_HOST:-192.168.20.202}"
PEER_HOST="${PEER_HOST:-192.168.20.203}"
OTHER_VLAN_HOST="${OTHER_VLAN_HOST:-192.168.30.1}"

PASS=0
FAIL=0
SKIP=0
SELECTED=("$@")

c_pass=$'\033[32m'; c_fail=$'\033[31m'; c_skip=$'\033[33m'; c_off=$'\033[0m'
[[ -t 1 ]] || { c_pass=""; c_fail=""; c_skip=""; c_off=""; }

want() {
  [[ ${#SELECTED[@]} -eq 0 ]] && return 0
  local n
  for n in "${SELECTED[@]}"; do [[ "$n" == "$1" ]] && return 0; done
  return 1
}

report() {
  local num="$1" name="$2" status="$3" detail="${4:-}"
  case "$status" in
    pass) PASS=$((PASS + 1)); printf '%s  ok  %s%2s  %s\n' "$c_pass" "$c_off" "$num" "$name" ;;
    fail) FAIL=$((FAIL + 1)); printf '%sFAIL  %s%2s  %s\n      %s\n' "$c_fail" "$c_off" "$num" "$name" "$detail" ;;
    skip) SKIP=$((SKIP + 1)); printf '%sskip  %s%2s  %s  (%s)\n' "$c_skip" "$c_off" "$num" "$name" "$detail" ;;
  esac
}

need() { command -v "$1" >/dev/null 2>&1; }

echo "VLAN 20 validation — gateway ${GATEWAY}"
echo

# 1 ------------------------------------------------------------------------
if want 1; then
  addr=$(ip -4 -o addr show scope global 2>/dev/null | awk '{print $4}' | head -1)
  route=$(ip -4 route show default 2>/dev/null | awk '{print $3}' | head -1)
  if [[ "$addr" == ${SUBNET_PREFIX}* && "$route" == "$GATEWAY" ]]; then
    report 1 "correct subnet and gateway" pass
  else
    report 1 "correct subnet and gateway" fail \
      "got addr=${addr:-none} gw=${route:-none}, want ${SUBNET_PREFIX}x/24 via ${GATEWAY}"
  fi
fi

# 2 ------------------------------------------------------------------------
# A common cause of failure here is the OPNsense rule having protocol TCP
# rather than "any" — ICMP is not TCP.
if want 2; then
  if ping -c3 -W2 "$GATEWAY" >/dev/null 2>&1; then
    report 2 "gateway reachable" pass
  else
    report 2 "gateway reachable" fail \
      "check the OPNsense Lab rule protocol is 'any', not TCP — ICMP is not TCP"
  fi
fi

# 3 ------------------------------------------------------------------------
if want 3; then
  if ! need dig; then
    report 3 "DNS via Unbound" skip "dig not installed (apt install dnsutils)"
  elif [[ -n "$(dig +short +time=3 +tries=1 github.com "@${GATEWAY}" 2>/dev/null)" ]]; then
    report 3 "DNS via Unbound" pass
  else
    report 3 "DNS via Unbound" fail "no answer from Unbound at ${GATEWAY}"
  fi
fi

# 4 ------------------------------------------------------------------------
# GET, not HEAD/-I: ghcr.io's root path answers HEAD with 405, which looks
# like a broken egress path but actually proves the opposite — DNS, TCP and
# TLS all completed and the server responded.
if want 4; then
  code=$(curl -sS -o /dev/null -w '%{http_code}' --max-time 10 https://ghcr.io 2>/dev/null)
  if [[ "$code" =~ ^(200|301|302)$ ]]; then
    report 4 "egress TCP to ghcr.io" pass
  else
    report 4 "egress TCP to ghcr.io" fail "got HTTP '${code:-none}'"
  fi
fi

# 5 ------------------------------------------------------------------------
# 1472 payload + 28 bytes of headers = 1500. If this fails you have an MTU
# problem, and it will resurface later as "some HTTPS sites hang" — which is a
# much worse way to discover it.
if want 5; then
  # "do" is quoted only to stop shellcheck reading it as a loop keyword
  # (SC1010); it is the argument to -M, the don't-fragment flag.
  if ping -M "do" -s 1472 -c3 -W2 1.1.1.1 >/dev/null 2>&1; then
    report 5 "path MTU 1500 without fragmentation" pass
  else
    report 5 "path MTU 1500 without fragmentation" fail \
      "set lab_mtu to 1492 in group_vars rather than chasing intermittent TLS hangs later"
  fi
fi

# 6 ------------------------------------------------------------------------
# ports.ubuntu.com, NOT archive.ubuntu.com, is the arm64 archive. Easy to miss
# when writing the Squid allowlist, and the failure looks like a broken mirror.
if want 6; then
  code=$(curl -sS -o /dev/null -w '%{http_code}' --max-time 10 -I http://ports.ubuntu.com 2>/dev/null)
  if [[ "$code" =~ ^(200|301|302)$ ]]; then
    report 6 "arm64 archive (ports.ubuntu.com) reachable" pass
  else
    report 6 "arm64 archive (ports.ubuntu.com) reachable" fail \
      "got HTTP '${code:-none}' — note it is ports.ubuntu.com, not archive.ubuntu.com"
  fi
fi

# 7 ------------------------------------------------------------------------
if want 7; then
  if ! need nc; then
    report 7 "VLAN 20 -> VLAN 10 denied" skip "nc not installed (apt install netcat-openbsd)"
  elif nc -w3 -z "$WORKSTATION_HOST" 22 >/dev/null 2>&1; then
    report 7 "VLAN 20 -> VLAN 10 denied" fail \
      "reached ${WORKSTATION_HOST}:22 — replace 'Allow Trusted to any' with 'Trusted -> !Internal_Networks'"
  else
    report 7 "VLAN 20 -> VLAN 10 denied" pass
  fi
fi

# 8 ------------------------------------------------------------------------
if want 8; then
  if ! need nc; then
    report 8 "VLAN 20 -> VLAN 30/40 denied" skip "nc not installed"
  elif nc -w3 -z "$OTHER_VLAN_HOST" 80 >/dev/null 2>&1; then
    report 8 "VLAN 20 -> VLAN 30/40 denied" fail "reached ${OTHER_VLAN_HOST}:80"
  else
    report 8 "VLAN 20 -> VLAN 30/40 denied" pass
  fi
fi

# 9, 10 --------------------------------------------------------------------
# Direction-dependent: these must be run FROM the workstation, so they are
# reported as skipped when run on a Pi rather than silently passing.
if want 9; then
  report 9 "VLAN 10 -> VLAN 20 SSH allowed" skip \
    "run from the workstation: ssh mchellmer@${MASTER_HOST}"
fi

if want 10; then
  if ! need nc; then
    report 10 "VLAN 10 -> VLAN 20 API server" skip "nc not installed"
  else
    report 10 "VLAN 10 -> VLAN 20 API server" skip \
      "run from the workstation: nc -vz ${MASTER_HOST} 6443 (needs the cluster to exist)"
  fi
fi

# 11 -----------------------------------------------------------------------
# This traffic is switch-local: the firewall never sees it. Which is exactly
# why inter-node workload isolation has to be a NetworkPolicy problem, not a
# firewall problem — see policy/.
if want 11; then
  if [[ "$(hostname -I 2>/dev/null | tr ' ' '\n' | grep -c "^${PEER_HOST}$")" -gt 0 ]]; then
    report 11 "intra-VLAN 20 Pi to Pi" skip "PEER_HOST is this host; set PEER_HOST to another node"
  elif ping -c3 -W2 "$PEER_HOST" >/dev/null 2>&1; then
    report 11 "intra-VLAN 20 Pi to Pi" pass
  else
    report 11 "intra-VLAN 20 Pi to Pi" fail "cannot reach ${PEER_HOST} (is it up?)"
  fi
fi

echo
printf 'passed %d   failed %d   skipped %d\n' "$PASS" "$FAIL" "$SKIP"
exit "$FAIL"
