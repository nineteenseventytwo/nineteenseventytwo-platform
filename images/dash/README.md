# dash

`ghcr.io/nineteenseventytwo/dash`

The 8bsl status page at `dash.eightbitsaxlounge.com`
([ADR-0018](../../docs/decisions/ADR-0018-personal-website.md) W5). For each
of the six eightbitsaxlounge services in `prod` and `dev`, it shows one of
these states:

| State | Meaning |
|---|---|
| running | ready replicas ≥ desired |
| degraded | some replicas not ready, but nothing crash-looping |
| crashing | a container is waiting on `CrashLoopBackOff`, an image-pull error or a config error |
| stopped | scaled to zero (`chat`'s normal state in whichever environment is not live) |
| unknown | the API server could not be read, or the workload does not exist |

"unknown" is rendered as a real row, not an empty table (09 W5). When the whole
cluster is down the page does not load at all, and Cloudflare's tunnel error is
the signal (09 F8).

## What it can touch

- **Reads:** pods, Deployments and StatefulSets in `eightbitsaxlounge-prod` and
  `eightbitsaxlounge-dev`, through the Roles in `policy/42-dash.yaml`. Nothing
  cluster-wide.
- **Network:** ingress only from cloudflared, egress only to DNS and the API
  server (`policy/10-default-deny.yaml`). No internet.
- **Browser:** no JavaScript at all. CSP `default-src 'none'; style-src 'self'`,
  and the page refreshes itself with a `<meta>` tag every 30 seconds.

No client-go: three authenticated GETs did not justify its dependency tree.
`go.mod` has no requirements, so the weekly image scan has only the Go
standard library and the distroless base to report on.

## Developing

```sh
cd images/dash
go vet ./... && go test -race ./...
```

`lint.yml`'s `go` job runs the same on every PR. The Dockerfile runs them
again in its build stage, so an image that fails them is never pushed.

## Versioning

Same two-workflow scheme as
[ansible-runner](../ansible-runner/README.md#versioning):

1. Bump `version.txt` on a branch. `image-dash-build.yml` builds, tests, signs
   (cosign, keyless), scans and smoke-tests the image.
2. Point `cluster/dash/10-deployment.yaml` at the **digest** that build
   pushed, in the same PR.
3. Merge. `image-dash-promote.yml` moves `:stable`. Argo CD rolls the
   Deployment, because the manifest names the digest, not a tag.
