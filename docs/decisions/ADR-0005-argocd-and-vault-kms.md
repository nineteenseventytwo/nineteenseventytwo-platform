# ADR-0005: Argo CD from the start; Vault with KMS auto-unseal

**Status:** Accepted
**Date:** 2026-08-07

## Context

Two questions that turn out to be one decision, because both are about what
reconciles the cluster and what it depends on.

**Addon delivery.** Either a pipeline runs `helm upgrade --install` against
`cluster/`, or a GitOps controller reconciles it. Pipeline-driven is simpler and
adequate at this size.

**Vault unseal.** Vault OSS seals itself on every restart and needs unseal keys
to come back. A Pi cluster reboots — kernel updates, power, moving a switch —
and each of those becomes a manual unseal at whatever hour it happens.

## Decision

**Argo CD from the start**, app-of-apps reconciling `cluster/`.

**Vault with AWS KMS auto-unseal**, paired with External Secrets Operator.

## Consequences — Argo CD

- Drift is corrected rather than merely detected. `selfHeal: true` means a
  hand-edit to the cluster is reverted, which is the property that makes "no
  `kubectl apply` from a laptop" enforceable rather than aspirational.
- Exactly one human-run `helm install` exists: `make bootstrap-argocd`.
- **Cilium is a genuine ordering problem.** The cluster has no working datapath
  until Cilium is installed, and Argo CD runs on that datapath. Resolved by
  having the Ansible playbook install it and the Application *adopt* the release,
  with playbook-injected values excluded from diffing.
- **Cost:** Argo CD is roughly 500 MB across its components on a cluster with
  ~6 GB total. That is real, and it is the main argument against.
- The lab has no inbound internet path, so webhooks are unavailable; Argo polls
  every 3 minutes. `make argocd-sync` forces a reconcile when that is too slow.

## Consequences — Vault + KMS

- No hand-unsealing, ever. That is the entire point.
- Exercises KMS key policy and IAM, which is worth having done.
- **Stated honestly: an on-prem cluster's secrets now depend on a cloud KMS
  being reachable and an IAM principal not being revoked.** That is a real
  dependency on a third party inside a lab whose whole design is about local
  control. It is the right trade because the alternative is not "no dependency",
  it is "a dependency on you being awake at 11pm".
- Recovery keys are **not** unseal keys under auto-unseal — they only permit
  `generate-root` and rekey. They still belong in a password manager, split.
- **ESO over the Vault CSI driver or Agent injector.** An `ExternalSecret`
  materialises an ordinary Kubernetes Secret, so app manifests carry no
  Vault-specific annotations and the same manifest can point at AWS Secrets
  Manager when a workload moves to the cloud. That backend-swap property is the
  argument.
- Single-node Vault with file storage on Longhorn. Raft HA across three 2 GB
  Pis costs more than the availability it buys; the data has two Longhorn
  replicas either way.

## Alternatives considered

**Pipeline-driven `helm upgrade`.** Simpler, fewer moving parts, and genuinely
adequate here. Rejected because drift correction and the audit trail are worth
the memory, and the directory layout supports either.

**Flux.** Lighter than Argo CD, which matters on these nodes. Rejected for Argo's
UI, which is worth a great deal when debugging a sync failure on a cluster you
visit intermittently.

**Shamir manual unseal.** Rejected — see above. If AWS becomes unavailable,
falling back to Shamir is a values change, not a redesign.
