# 08 — Security controls: what watches what

Every security control in the lab and the AWS org: what each one looks at,
when it runs, and where its findings go. The diagrams draw the same picture by
layer: [`access-controls`](../diagrams/access-controls.drawio) for prevention,
[`security-awareness`](../diagrams/security-awareness.drawio) for detection, and
[`shift-left`](../diagrams/shift-left.drawio) for the gates before a change
lands.

## Detection

They divide by **what they look at** and **when**. Each one answers a question
the others cannot.

| Control | Looks at | When | Question | Findings go to |
|---|---|---|---|---|
| **Trivy, secret scan** | Every file in each repo | Every PR, **blocking** ([ADR-0019](decisions/ADR-0019-public-repos-blocking-secret-scan.md)) | Is a credential about to be made public? | Fails the PR |
| **Checkov** | IaC as written: Kubernetes YAML, Dockerfiles, Terraform, workflows | Every PR (advisory) | Is this configuration risky as committed? | Code scanning; a *new* alert in changed code fails the check |
| **Trivy, image scan** | Every image the cluster is actually running | Weekly, Monday 06:00 | Does what we run have known, fixable CVEs? | Code scanning, plus a count in Slack |
| **Kubescape** | The **live** cluster, chart defaults included | Nightly, 03:30 | Does the running cluster still match its reviewed baseline? | Alertmanager → Slack, new failures only ([ADR-0017](decisions/ADR-0017-kubescape-accepted-controls.md)) |
| **Falco** | System calls on every node | Continuously | Is something *doing* something bad right now? | Alertmanager → Slack |
| **Prowler** | AWS account configuration (CIS, AWS FSBP) | Daily, 05:00 | Is the AWS estate configured safely? | S3 findings bucket (kept out of the public repo's logs) |
| **IAM Access Analyzer** | Resource and trust policies, org as zone of trust | Continuously | Can anything outside the org reach this? | Its findings list; external-by-design ones archived |
| **GuardDuty** | AWS API activity and threat intelligence | Continuously | Is someone attacking or misusing an account? | GuardDuty console — no notification route yet |
| **CloudTrail + EventBridge** | Root sign-in, break-glass, `OrganizationAccountAccessRole` | On the event | Did one of the never-routine things happen? | SNS → email |
| **Asset graph** (Steampipe, cloud repo) | Every AWS account, as SQL tables | When you ask | Attack-path questions the managed tools cannot express | Write-ups in the cloud repo's `docs/asset-graph/` |

### Where they overlap, and why that is fine

- **Checkov vs Kubescape.** Both read Kubernetes configuration. Checkov reads
  what is *in git* before merge. Kubescape reads what is *running*, including
  values a chart renders that Checkov never sees. Falcosidekick's missing
  `runAsGroup` was a chart default: only Kubescape caught it.
- **Kubescape vs Falco.** Configuration versus behaviour. A privileged pod is a
  Kubescape finding; a shell spawned inside it is a Falco alert.
- **Trivy vs Checkov.** Trivy covers secrets and known vulnerabilities in
  packages and images. Checkov covers misconfiguration. Trivy's misconfig
  scanner overlaps Checkov a little; nothing depends on it.
- **Prowler, Access Analyzer, GuardDuty, asset graph.** Posture, exposure,
  threats, and questions. Access Analyzer reports "any GitHub repo may assume
  this" and "this repo's `aws-prod` environment may" identically; the asset
  graph's `external-trust` query tells them apart.

## Prevention

What stops a thing, rather than reporting it:

| Layer | Control |
|---|---|
| Admission | Pod Security Admission per namespace (`policy/00-namespaces.yaml`): `baseline` cluster-wide, `restricted` where the workload allows it |
| Pod network | Cilium NetworkPolicy: default-deny in every namespace, explicit allows in `policy/10-default-deny.yaml` |
| Node | ufw on every node: deny inbound except listed cluster and metrics ports |
| Network | OPNsense between VLANs; no inbound port-forwards (external scan, 2026-10-27) |
| Edge | Cloudflare Access in front of private hostnames, which are reachable only through the tunnel ([ADR-0021](decisions/ADR-0021-private-hostnames-tunnel-only.md)) |
| Resources | LimitRange and ResourceQuota per namespace ([ADR-0016](decisions/ADR-0016-cpu-limits-from-limitrange.md)) |
| AWS org | SCPs and RCPs at the root, including the region and cost denies (cloud repo) |
| Change | Required checks and signed commits on `main`; Terraform applies behind the `aws-prod` environment's reviewer |

**Egress is observed, not yet enforced** (07 Phase 6.4). Squid on OPNsense logs
the nodes' traffic. Cilium's DNS proxy and Hubble record every name a pod
resolves (`policy/12-egress-observe.yaml`, `tests/egress-observed.sh`). Phase 7
turns both lists into allowlists.

## Identity: no long-lived credentials

| Who | Gets credentials how |
|---|---|
| People | AWS Identity Center (SSO); SSH certificates signed by Vault, valid five minutes |
| CI → AWS | GitHub OIDC; each role pinned to a repo's numeric ID and an environment |
| Pods → AWS | IRSA through the pod-identity webhook: one role per ServiceAccount ([06](06-aws-federation.md)) |
| Pods → secrets | Vault through External Secrets; nothing secret in git except SOPS-encrypted values |
| Apps → GitHub | GitHub Apps, one per purpose: ARC's for runner registration, `nineteenseventytwo-findings` for code-scanning read |

The exceptions — credentials that do not expire — are listed with their blast
radius in [04-secrets.md](04-secrets.md#secret-inventory).

## One place findings land

- **Slack**: Falco, Kubescape regressions, and every Alertmanager alert,
  including the ones that say a detector has stopped (`KubeJobFailed`,
  `FindingsSourceDown`, `ProwlerReportStale`).
- **The `Findings` dashboard** in Grafana: Falco, Kubescape, Trivy, Checkov and
  Prowler as counts by source, severity, item and age (`cluster/findings`,
  `images/findings-exporter`). Detail stays where each tool keeps it.
- **Email**: the AWS sign-in and budget alarms.

## Known gaps

- **GuardDuty findings** have no notification route.
- **API-server audit logs** are not collected anywhere central.
- **Grafana and Argo CD** are LAN-only behind their own logins, not Cloudflare
  Access (07 8.2).
- **Longhorn's `libexpat` criticals** wait on an upstream release.
- **The detection drill** (07 10.5) has not been run, so detection times are
  unmeasured.
- **No on-call:** one person, one Slack channel and one mailbox.
