# kubescape-gate

`ghcr.io/nineteenseventytwo/kubescape-gate`

Compares a Kubescape NSA scan with the list of failures this cluster accepts,
and alerts on the difference (07 Phase 10.2,
[ADR-0017](../../docs/decisions/ADR-0017-kubescape-accepted-controls.md)).
It runs as the second step of the nightly CronJob in `cluster/kubescape`,
after Kubescape writes its JSON.

| Result | What happens |
|---|---|
| A failing (control, resource) pair not in the list | **Regression.** One Alertmanager alert per control, `alertname=KubescapeRegression`, listing the resources. It stays firing for 25h, so it lapses only if the next night's scan is clean |
| A listed pair that no longer fails | **Stale.** Logged only. Delete it from the list, or, if the resource still exists, check the scan's RBAC (`policy/43-kubescape.yaml`) |
| No scan, an empty scan, an unreadable list, Alertmanager refusing the alert | **Exit 1.** The Job fails and `KubeJobFailed` fires. A gate that silently stopped running would look exactly like a clean cluster |

Resources are compared as `namespace/Kind/name`. Hex runs of 8 or more
characters become `*`, so generated names (Longhorn's instance-managers, ARC's
listeners) survive upgrades.

The list is `cluster/kubescape/00-accepted.yaml`. Accepting a finding is a PR
that adds the pair under its control, with the reason.

## Developing

```sh
cd images/kubescape-gate
go vet ./... && go test -race ./...
```

Against a real scan:

```sh
GATE_SCAN=scan.json GATE_ACCEPTED=accepted.txt go run .
```

No `GATE_ALERTMANAGER` means log only.

## Versioning

Same two-workflow scheme as [dash](../dash/README.md#versioning): bump
`version.txt` on a branch, point `cluster/kubescape/10-cronjob.yaml` at the
digest the build pushed, and merge.
