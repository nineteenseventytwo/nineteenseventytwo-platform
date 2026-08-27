# tests/

## network-check.sh

The §2.3 validation matrix, runnable. Run it on a Pi on a VLAN 20 access port
**before** installing anything, and again after every firewall change — that
re-runnability is the reason it is a script and not a table in a document.

```bash
tests/network-check.sh          # all 12 tests
tests/network-check.sh 5 6      # just the MTU and arm64-archive tests
```

Exit code is the failure count, so CI can gate on it.

Tests 9 and 10 are direction-dependent and report as **skipped** on a Pi rather
than silently passing — they have to be run from the workstation:

```powershell
ssh mchellmer@192.168.20.202       # test 9
nc -vz 192.168.20.202 6443         # test 10, once the cluster exists
```

Overridable via environment: `LAB_GATEWAY`, `LAB_SUBNET_PREFIX`,
`WORKSTATION_HOST`, `MASTER_HOST`, `PEER_HOST`, `OTHER_VLAN_HOST`.

## goss/node.yaml

Node baseline assertions — the properties that produce a confusing failure
somewhere else when they quietly stop being true.

```bash
curl -fsSL https://github.com/goss-org/goss/releases/latest/download/goss-linux-arm64 \
  -o /usr/local/bin/goss && chmod +x /usr/local/bin/goss
goss -g tests/goss/node.yaml validate --format documentation
```

`memory-cgroups-enabled` will fail on `1972-console-1`, correctly — it is not a
cluster node and does not need memory cgroups.

## verify-default-deny.sh

Asserts every namespace has a `default-deny-all` NetworkPolicy or is on the
explicit exemption list at the top of `policy/10-default-deny.yaml`. Exists
because "default-deny in every namespace" was true of the README, not the
cluster, for months — this makes it a check instead of a claim.

```bash
make verify-default-deny
```

Exit code is the count of uncovered, unexempted namespaces.

## What is deliberately not tested here

Cluster conformance and CIS benchmarking. Run Kubescape against the **empty**
hardened cluster and commit the result as the baseline artefact, before any
workload exists to muddy it:

```bash
kubescape scan framework nsa --format json --output baseline-nsa.json
```

A before/after pair across the Cilium and default-deny work is worth more than
either scan alone.
