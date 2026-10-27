# findings-exporter

`ghcr.io/nineteenseventytwo/findings-exporter`

Every security finding source on this platform, reduced to one set of
Prometheus metrics for the `Findings` Grafana dashboard (07 Phase 10.4).

| Source | Read from | Item label | Refresh |
|---|---|---|---|
| falco | active alerts in Alertmanager | Falco rule | 1m |
| kubescape | active alerts in Alertmanager | control | 1m |
| trivy | open code-scanning alerts on GitHub | image repository (or rule) | 15m |
| checkov | open code-scanning alerts on GitHub | rule | 15m |
| prowler | newest `*.ocsf.json` in the findings bucket, unmuted FAILs | check ID | 1h |

Severities are normalised to `critical`, `high`, `medium`, `low`, `info` and
`unknown`, so the dashboard can sort across tools.

**Counts, not detail.** Nothing per-resource leaves its source: Prowler's
resource IDs stay in the bucket, CVE text stays in the Security tab. The view
exists to decide what to look at first.

## Metrics

| Metric | Meaning |
|---|---|
| `findings_open{source,severity,item}` | open findings |
| `findings_oldest_open_timestamp_seconds{source,severity}` | first-seen time of the oldest; not set for Prowler, whose timestamps are the scan's |
| `findings_source_up{source}` | 1 if the last refresh succeeded. A failed refresh keeps the last counts, so a broken source never reads as a clean one |
| `findings_source_last_success_timestamp_seconds{source}` | last successful refresh |
| `findings_source_data_timestamp_seconds{source}` | Prowler: when the newest report was written |

`cluster/findings/50-prometheusrule.yaml` alerts on a source down for 2h, a
Prowler report older than ~2 days, and the exporter not being scraped.

## Credentials

- **GitHub:** its own GitHub App, *Code scanning alerts: read* on the platform
  repo only (`cluster/vault/README.md#findings-exporter`). Not ARC's App,
  which can administer the org's runners. A JWT signed with the App key buys a
  one-hour installation token, narrowed to `security_events: read` in the
  request (`githubapp.go`). In the cluster the Secret is mounted at
  `FINDINGS_GITHUB_APP_DIR` (`app-id`, `installation-id`, `private-key`). Locally, `FINDINGS_GITHUB_TOKEN_FILE` takes any
  token instead.
- **AWS:** none stored. The pod-identity webhook (ADR-0014) mounts a projected
  token, exchanged with STS for `cluster-findings-exporter` (cloud repo), which
  can list and read `findings/` in the Prowler bucket. The STS and S3 calls are
  signed by hand in `sigv4.go`, tested against AWS's published examples, so
  there is no SDK in the image.

## Developing

```sh
cd images/findings-exporter
go vet ./... && go test -race ./...
```

Locally against GitHub only:

```sh
gh auth token > /tmp/t && FINDINGS_GITHUB_REPOS=nineteenseventytwo/nineteenseventytwo-platform \
  FINDINGS_GITHUB_TOKEN_FILE=/tmp/t go run . & curl -s localhost:8080/metrics
```

## Versioning

Same two-workflow scheme as [dash](../dash/README.md#versioning).
