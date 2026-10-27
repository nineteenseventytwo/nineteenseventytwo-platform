#!/usr/bin/env bash
# Prints the external names pods have resolved, by namespace: the observed
# half of Phase 7's allowlist (07 Phase 6.4). The other half, the nodes' own
# traffic, is in Squid's access log on OPNsense.
#
#   tests/egress-observed.sh          # last 7d, external names only
#   tests/egress-observed.sh 24h      # a shorter window
#   ALL=1 tests/egress-observed.sh    # include cluster.local names too
#
# The data is hubble_dns_queries_total, which exists only because
# policy/12-egress-observe.yaml sends pod DNS through Cilium's DNS proxy.
# Prometheus keeps 7d (cluster/monitoring/values.yaml), so a name a job
# resolves less often than weekly falls out of the window. Run it after a full
# week, and keep the output (docs/egress-observed.md), rather than trusting one
# run.
#
# A resolved name is not a connection. A pod that resolves a name and then
# never connects still appears here, which errs towards a longer allowlist,
# the safe direction for log-only. A pod that connects to a literal IP, with
# no DNS at all, does not appear. `hubble observe --to-identity world` finds
# those.
#
# Requires kubectl pointed at the cluster (./build/kubeconfig), curl and
# python3. Exits 125 if Prometheus could not be queried, 1 if it answered with
# no data, else 0.
set -uo pipefail

UNREACHABLE=125
WINDOW="${1:-7d}"
PORT="${PROM_LOCAL_PORT:-19090}"

kubectl -n monitoring port-forward svc/monitoring-kube-prometheus-prometheus \
  "$PORT:9090" >/dev/null 2>&1 &
PF=$!
trap 'kill "$PF" 2>/dev/null' EXIT

QUERY="sum by (source, query) (increase(hubble_dns_queries_total[$WINDOW])) > 0"
for _ in 1 2 3 4 5 6 7 8 9 10; do
  if OUT=$(curl -fsS --max-time 20 "http://127.0.0.1:$PORT/api/v1/query" \
      --data-urlencode "query=$QUERY" 2>/dev/null); then
    break
  fi
  OUT=""
  sleep 1
done
if [ -z "$OUT" ]; then
  echo "error: could not query Prometheus — is kubectl pointed at the cluster?" >&2
  exit "$UNREACHABLE"
fi

ALL="${ALL:-0}" python3 -c '
import json, os, sys
rows = json.load(sys.stdin)["data"]["result"]
out = []
for r in rows:
    m = r["metric"]
    q = m.get("query", "")
    if os.environ["ALL"] != "1" and (q.endswith(".cluster.local.") or q.count(".") < 2):
        continue
    out.append((m.get("source", "?"), q.rstrip("."), round(float(r["value"][1]))))
if not out:
    print("no data - is policy/12-egress-observe.yaml applied, and has the window filled?", file=sys.stderr)
    sys.exit(1)
w = max(len(ns) for ns, _, _ in out)
for ns, q, n in sorted(out):
    print(f"{ns:<{w}}  {q}  ({n})")
' <<<"$OUT"
