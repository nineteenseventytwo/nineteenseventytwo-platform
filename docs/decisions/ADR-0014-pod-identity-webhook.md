# ADR-0014: Deploy the EKS pod-identity-webhook for cluster→AWS federation

**Status:** Accepted
**Date:** 2026-08-20

## Context

Four workloads in this cluster need AWS credentials — Vault to auto-unseal
against a KMS CMK, Longhorn to write volume backups, Argo CD to decrypt
SOPS-with-KMS values, and eventually Prowler to file findings. The cloud repo
publishes the cluster's OIDC discovery documents and creates one IAM role per
service account
([cloud ADR-0006](https://github.com/nineteenseventytwo/nineteenseventytwo-cloud/blob/main/docs/decisions/ADR-0006-public-cluster-oidc-issuer.md)),
so the trust relationship exists. What remains is the mechanical part: a pod
needs `AWS_ROLE_ARN`, `AWS_WEB_IDENTITY_TOKEN_FILE`, and a service-account
token projected with audience `sts.amazonaws.com`, before any AWS SDK inside it
will attempt `AssumeRoleWithWebIdentity`.

Nothing in Kubernetes does that by default. On EKS it is done by a mutating
admission webhook that AWS publishes as open source, and which reads a single
annotation on the ServiceAccount.

The alternative is to write those two environment variables and the projected
volume into each chart's values by hand.

## Decision

Deploy `amazon-eks-pod-identity-webhook` at sync wave 25 — after cert-manager,
which issues its serving certificate, and before Longhorn and Vault. Workloads
then carry only an `eks.amazonaws.com/role-arn` annotation on their
ServiceAccount.

Three deviations from the upstream manifests, each deliberate:

- **Run non-root on port 8443**, with the Service mapping 443 to it. The image
  carries no `USER` directive, and binding a port below 1024 as a non-root user
  would need `NET_BIND_SERVICE`. Granting a capability to avoid changing a port
  number is the wrong trade.
- **`admissionReviewVersions: ["v1"]`**, not upstream's `["v1beta1"]`. The
  v1beta1 AdmissionReview was removed in Kubernetes 1.22; leaving it as shipped
  means the API server can negotiate no common version and every call fails.
- **A read-only ClusterRole.** Upstream also grants `secrets` write and
  `certificatesigningrequests` create, both of which belong to the
  `--in-cluster=true` mode where the webhook mints its own serving certificate.
  This deployment takes its certificate from cert-manager, so neither is ever
  exercised.

## Consequences

- Adding a workload to the federation is one annotation. No environment
  variables, no volume definitions, no per-chart boilerplate to get subtly
  wrong four times.
- The pattern is byte-for-byte what EKS does, so it transfers directly — both
  to a real EKS cluster and to explaining it out loud.
- **A mutating admission webhook now sits in the pod creation path**, costing
  ~50Mi and one more thing that can be down. It is scoped by
  `namespaceSelector` to `argocd`, `vault`, `longhorn-system` and `security`,
  so a failure cannot affect pod creation anywhere else.
- **It fails open, and that is the uncomfortable half.** `failurePolicy:
  Ignore` means a broken webhook produces pods that start perfectly and have no
  AWS credentials, with nothing in their own events to say why. The symptom
  surfaces as Vault refusing to unseal or backups quietly failing. `Fail` was
  rejected because on a three-node lab it turns one crashlooping pod into an
  outage you cannot deploy your way out of. The mitigation is documentation:
  "check the webhook pod first" is written into
  [06-aws-federation.md](../06-aws-federation.md) and `cluster/vault/README.md`.
- **Argo CD is installed before the webhook exists**, by `make
  bootstrap-argocd`, so `argocd-repo-server` needs one manual restart after
  first bootstrap to pick up injection. Documented rather than automated,
  because it happens exactly once per cluster lifetime.
- The webhook has its own self-signed cert-manager `Issuer` rather than using
  the shared `internal-ca` ClusterIssuer, which is not applied until sync wave
  90. A webhook's serving certificate has exactly one consumer, told the CA out
  of band by cainjector, so nothing is lost.

## Alternatives considered

**Write the env vars and projected volume into each chart's values.** No new
component, nothing mutating pods, and genuinely defensible at four workloads.
Rejected because the boilerplate is ~15 lines per chart repeated verbatim,
every chart must happen to support `extraVolumes` *and* `extraEnv`, and the
failure mode of getting the audience wrong in one of four places is the same
silent one — without a single place to look. It also diverges from EKS, which
costs the transferability that is much of the point of doing IRSA here at all.

**A Helm chart for the webhook.** AWS publishes manifests, not a chart, and the
community charts add a dependency to track for four files that need three
deliberate deviations from upstream anyway.
