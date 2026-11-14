# Observed egress

The input to Phase 7's allowlists ([07](plan/07-completion-plan.md) Phase
6.4). Two paths, two lists: pods (Cilium DNS proxy and Hubble) and nodes
(Squid on OPNsense). Neither is enforced yet.

## Pods

`tests/egress-observed.sh 7d`, run 2026-11-11. The window is 2026-11-04 to
2026-11-11. Count is DNS queries in the window, not connections.

| Namespace | Names | Notes |
|---|---|---|
| `arc-runners` | `broker.actions.githubusercontent.com`, `results-receiver.actions.githubusercontent.com`, `run-actions-1-azure-eastus.actions.githubusercontent.com`, `productionresultssa1.blob.core.windows.net` | The `run-actions-*` and `productionresults*` names are GitHub-assigned and change. Allow `*.actions.githubusercontent.com` and `*.blob.core.windows.net`, or accept breakage |
| `arc-systems` | `api.github.com`, `broker.actions.githubusercontent.com` | |
| `argocd` | `github.com`, `ghcr.io`, `pkg-containers.githubusercontent.com`, `release-assets.githubusercontent.com`, `charts.external-secrets.io`, `external-secrets.io`, `charts.jetstack.io`, `charts.longhorn.io`, `falcosecurity.github.io`, `helm.cilium.io`, `helm.releases.hashicorp.com`, `metallb.github.io`, `postfinance.github.io`, `prometheus-community.github.io` | One Helm repo per chart in `cluster/argocd/applications/`. A new chart repo needs adding here too |
| `cert-manager` | `acme-v02.api.letsencrypt.org`, `acme-staging-v02.api.letsencrypt.org` | Staging is still resolved, so a staging issuer is still in use somewhere. Check before allowlisting it |
| `cloudflared` | `region1.v2.argotunnel.com`, `region2.v2.argotunnel.com`, `cfd-features.argotunnel.com`, `update.argotunnel.com` | `update.` is the self-update check. The image is pinned, so it can be denied |
| `eightbitsaxlounge-dev` | `api.twitch.tv`, `id.twitch.tv`, `eventsub.wss.twitch.tv`, `cell-a.eventsub.wss.twitch.tv` | `cell-*` is Twitch-assigned: allow `*.eventsub.wss.twitch.tv` |
| `eightbitsaxlounge-prod` | (none) | Prod chat was shed during the window, so nothing appears. It needs the same Twitch names as dev |
| `findings` | `api.github.com`, `sts.eu-west-2.amazonaws.com`, `nineteenseventytwo-prowler-517148962038.s3.eu-west-2.amazonaws.com` | |
| `kubescape` | `github.com`, `release-assets.githubusercontent.com`, `tuf-repo-cdn.sigstore.dev` | |
| `longhorn-system` | `sts.eu-west-2.amazonaws.com`, `nineteenseventytwo-longhorn-backups-972034964468.s3.eu-west-2.amazonaws.com`, `longhorn-upgrade-responder.rancher.io` | `upgrade-responder` is the version phone-home. Turn it off (`upgradeChecker: false`) rather than allowlist it |
| `monitoring` | `hooks.slack.com`, `grafana.com`, `stats.grafana.org` | `stats.` is Grafana's usage reporting and `grafana.com` is its update and plugin check. Turn both off (`analytics.reporting_enabled`, `analytics.check_for_updates`) rather than allowlist them |
| `vault` | `kms.eu-west-2.amazonaws.com`, `sts.eu-west-2.amazonaws.com` | Auto-unseal. Denying KMS means Vault cannot unseal after a restart |

Caveats for this window:

- **A power cut on 2026-11-08.** Every node restarted. Prometheus data is on
  Longhorn and survived, so the window is continuous. Afterwards Longhorn's
  instance-managers had no AWS credentials (see
  [07-runbooks](07-runbooks.md), "Credentials after a reboot"), and the
  nightly backup retries made `longhorn-system`'s STS lookups climb from about
  0.6/s to 32/s. The name is right. The volume is not typical.
- **Weekly or rarer jobs fall out.** Prometheus keeps 7d. A certificate
  renewal or chart-repo refresh that happens less often than weekly may be
  missing. The Let's Encrypt names did appear.
- **Literal IPs do not appear.** Run `hubble observe --to-identity world`
  before enforcing to catch anything connecting without DNS.

## Nodes

TODO: Squid's access log on OPNsense, same window. Unique destination
hosts, by source IP:

```sh
# on OPNsense
awk '{print $3, $7}' /var/log/squid/access.log \
  | sed -E 's#(https?://)?([^/:]+).*#\2#' | sort | uniq -c | sort -rn
```

Cluster nodes' apt does not go through Squid (only containerd does), so the
OPNsense firewall log covers `ports.ubuntu.com` and `security.ubuntu.com`.
