# 06 — AWS federation (IRSA on kubeadm)

Pods in this cluster reach AWS — Vault to auto-unseal, Longhorn to back up
volumes, Argo CD to decrypt SOPS-with-KMS, Prowler to file findings — and none
of them holds a credential. Each presents a projected service-account token to
STS and gets an hour of access to exactly one role.

The AWS half lives in [`nineteenseventytwo-cloud`](https://github.com/nineteenseventytwo/nineteenseventytwo-cloud);
this page is the cluster half and the join between them.

> **Read this before `make deploy-cluster`.** The API server's
> `--service-account-issuer` is fixed at `kubeadm init`. Get it wrong and the
> only fix is rebuilding the control plane.

---

## How it works

EKS does nothing privileged to make IRSA work. It publishes an OIDC discovery
document for the cluster, registers it with IAM, and lets pods exchange a
projected service-account token for AWS credentials. A kubeadm cluster does the
same thing with three API server flags and a public URL.

```
  pod                     API server            Cloudflare + S3           AWS STS
   │                          │                        │                     │
   │  projected SA token      │                        │                     │
   │  aud=sts.amazonaws.com   │                        │                     │
   │◀─────────────────────────│  signed with the       │                     │
   │                          │  SA signing key        │                     │
   │                                                                         │
   │  AssumeRoleWithWebIdentity(token)                                       │
   ├────────────────────────────────────────────────────────────────────────▶│
   │                                                   │                     │
   │                          GET /openid/v1/jwks      │◀────────────────────│
   │                                                   │  public signing key │
   │                                                   ├────────────────────▶│
   │                                                                         │
   │  temporary credentials, 1 hour, one role                                │
   │◀────────────────────────────────────────────────────────────────────────│
```

Three things have to agree, or nothing works:

| Thing | Where it is set | Value |
|---|---|---|
| Issuer | `--service-account-issuer` at `kubeadm init` | `https://oidc.eightbitsaxlounge.com` |
| Issuer | `issuer` field in the published discovery document | must match, character for character |
| Issuer | IAM OIDC provider `url` | must match |
| Audience | `--api-audiences` on the API server | includes `sts.amazonaws.com` |
| Audience | `aud` condition on each role's trust policy | `sts.amazonaws.com` |
| Subject | `sub` condition on each role's trust policy | `system:serviceaccount:<ns>:<name>` |

The JWKS is public, and that is not a compromise. It contains public signing
keys — the same thing Google and GitHub publish openly. AWS STS never calls
into the lab; it fetches a public key and verifies a signature on a token it
was handed. The security boundary is the `sub`/`aud` condition on each role.
Anyone can read the JWKS; only this API server can sign a token that satisfies
both, and only for a service account that exists.

---

## The rollout, in order

The order below is not a preference. Each step is blocked by the one before it,
and two of the dependencies are circular if you approach them the other way
round.

### 0. Before anything: confirm the issuer

```bash
grep -A2 cluster_oidc_issuer ansible/inventory/lab/group_vars/all/vars.yml
```

Must be `https://oidc.eightbitsaxlounge.com` — matching
`cluster.oidc_issuer` in `nineteenseventytwo-cloud/config/aws.json`, with
**no trailing slash**. `kube_control_plane` asserts both before it will run
`kubeadm init`, but knowing why the assert exists is the point.

### 1. Create the JWKS bucket (AWS)

The bucket must exist before the cluster can publish into it. It is gated
separately from the provider registration precisely because of that:

In `nineteenseventytwo-cloud/live/aws/platform-prod/variables.tf`, flip the
committed default:

```hcl
variable "create_jwks_bucket" {
  default = true    # was false
}
```

That repo has no `.tfvars` and no `-var` passthrough on purpose — the committed
config is the only variable source ([ADR-0004](https://github.com/nineteenseventytwo/nineteenseventytwo-cloud/blob/main/docs/decisions/ADR-0004-committed-account-ids.md)),
so a rollout flag is a reviewable one-line diff rather than something typed at a
terminal and forgotten. Open it as a PR: `terraform-plan.yml` posts the plan,
and on merge `terraform-apply.yml` applies it behind the `aws-prod` environment
gate, which needs a human.

To run it by hand instead, from the same account:

```bash
make plan  STACK=platform-prod
make apply STACK=platform-prod
```

Leave `publish_cluster_oidc` at `false`. Turning both on at once cannot work —
registering the provider requires the discovery document to be live, and the
document has nowhere to live until this step has run. Terraform enforces the
ordering with a variable validation rather than trusting you to remember it.

Note what else this does: it lifts the **account-level** S3 public access
block on `platform-prod`, because that block would otherwise override the JWKS
bucket policy. Every other bucket in the account carries its own block
explicitly. That trade is recorded in
[ADR-0006](https://github.com/nineteenseventytwo/nineteenseventytwo-cloud/blob/main/docs/decisions/ADR-0006-public-cluster-oidc-issuer.md).

```bash
make output STACK=platform-prod    # note jwks_bucket and jwks_origin_host
```

### 2. Build the cluster

```bash
make deploy-cluster
```

`kubeadm init` bakes the issuer in. Confirm it took:

```bash
make kubeconfig
kubectl get --raw /.well-known/openid-configuration | jq .issuer
# "https://oidc.eightbitsaxlounge.com"
```

If that prints `https://kubernetes.default.svc`, the cluster was built without
the issuer and **IRSA cannot work on it**. Nothing downstream will fix that —
the control plane has to be rebuilt. This is the failure the assert in
`kube_control_plane` exists to prevent.

### 3. Publish the discovery documents

```bash
make publish-oidc
```

Reads both documents from the API server, checks the `issuer` inside matches,
uploads them to the two protocol-defined keys, and then tries to fetch them
back over the public URL. It will fail at that last check until step 4 — that
is expected and the message says so.

### 4. Wire up Cloudflare

Two things in the Cloudflare dashboard for `eightbitsaxlounge.com`:

**a. Deploy the Worker.** Workers & Pages → Create → Worker. Paste
[`bootstrap/oidc/worker.js`](../bootstrap/oidc/worker.js) and deploy. Check
`ORIGIN_HOST` at the top matches `jwks_origin_host` from step 1.

**b. Route it.** Add a route `oidc.eightbitsaxlounge.com/*` pointing at the
Worker, and an `oidc` DNS record — an `AAAA` to `100::` (the discard prefix),
proxied. The record only exists to give the proxy something to attach to; the
Worker intercepts before the origin is ever consulted.

*Why a Worker and not a plain CNAME to S3:* the bucket policy denies
`aws:SecureTransport=false`, so the S3 website endpoint (HTTP-only) is refused
outright — which rules out the usual "CNAME to the website endpoint with
Flexible SSL" trick, and rightly so, since it would put the discovery document
on a plaintext hop. The REST endpoint speaks HTTPS but presents a certificate
for `*.s3.eu-west-2.amazonaws.com`, so proxying to it by CNAME needs either an
Enterprise-only SNI override or dropping to Full (non-strict) SSL and not
validating the origin at all. The Worker fetches by the origin's real hostname,
so TLS validates normally end to end.

Now verify from **outside** the lab network:

```bash
curl https://oidc.eightbitsaxlounge.com/.well-known/openid-configuration
curl https://oidc.eightbitsaxlounge.com/openid/v1/jwks
```

Both must return 200 and valid JSON. Re-run `make publish-oidc` — it should
now pass its own verification.

### 5. Register the provider and create the roles (AWS)

Only now:

Flip the second flag the same way, leaving the first one on:

```hcl
variable "publish_cluster_oidc" {
  default = true    # was false
}
```

```bash
make plan  STACK=platform-prod
make apply STACK=platform-prod
```

If the URL does not resolve, this fails with something that reads like a
permissions error and sends you looking in entirely the wrong place. That is
the whole reason for the gate.

```bash
make output STACK=platform-prod    # cluster_role_arns
```

Cross-check those four ARNs against `aws_cluster_role_arns` in
`ansible/inventory/lab/group_vars/all/vars.yml` and the annotations in
`cluster/*/values.yaml`. They are committed on both sides deliberately — a role
ARN is not a credential, and the trust policy is what decides.

### 6. Bootstrap Argo CD

```bash
make bootstrap-argocd
make argocd-sync-wait
```

The `pod-identity-webhook` Application lands at sync wave 25 — after
cert-manager issues its serving certificate, before Longhorn and Vault start.

**One manual step.** Argo CD is installed by `make bootstrap-argocd`, which
runs *before* the webhook exists, so `argocd-repo-server` did not pass through
admission and carries no injected credentials. Restart it once:

```bash
kubectl -n argocd rollout restart deploy/argocd-repo-server
```

### 7. Verify the whole chain

```bash
make verify-irsa
```

Or by hand, which is worth doing once so the mechanism is not a black box:

```bash
# the annotation the webhook reads
kubectl -n vault get sa vault -o jsonpath='{.metadata.annotations}'

# what the webhook injected
kubectl -n vault get pod -l app.kubernetes.io/name=vault \
  -o jsonpath='{.items[0].spec.containers[0].env}' | jq

# the actual proof: an assumed-role identity from inside a pod
kubectl -n vault exec -it vault-0 -- sh -c \
  'wget -qO- https://sts.eu-west-2.amazonaws.com/?Action=GetCallerIdentity\&Version=2011-06-15'
```

---

## Operational notes

### Rotation discipline

If the cluster's service-account signing key is ever rotated, **republish the
JWKS immediately**:

```bash
make publish-oidc
```

Rotating without republishing invalidates every projected token in the cluster
at once. The failure is instant and total, not gradual. This belongs on the
rotation checklist next to the SSH CA.

### The issuer URL is permanent

It is in the API server's flags and in every role trust policy. Treat it as
immutable for the life of the cluster. `kube_control_plane` refuses to run if
the inventory and the running control plane disagree, rather than rendering a
config that quietly does nothing.

### Availability

If Cloudflare or S3 is down, pods cannot get *fresh* AWS credentials. Cached
credentials keep working for the rest of their hour, and nothing that does not
touch AWS is affected. This is a dependency in the path of the cluster's AWS
access, not in the path of the cluster.

The exception worth naming: Vault cannot auto-unseal while KMS is unreachable.
A reboot during an AWS outage means a sealed Vault, which means ESO cannot
resolve `ExternalSecret`s. That is the cost of not hand-unsealing at 11pm, and
[ADR-0005](decisions/ADR-0005-argocd-and-vault-kms.md) takes it knowingly.

### When it fails

`InvalidIdentityToken` or `AccessDenied` on `AssumeRoleWithWebIdentity` is
almost always one of four things, in this order of likelihood:

1. **The `sub` disagrees.** Print the token's claims and compare against the
   trust policy rather than loosening the condition:
   ```bash
   kubectl -n vault exec vault-0 -- \
     cat /var/run/secrets/eks.amazonaws.com/serviceaccount/token \
     | cut -d. -f2 | base64 -d 2>/dev/null | jq '{iss, sub, aud}'
   ```
2. **The webhook did not fire.** `failurePolicy: Ignore` means a broken webhook
   produces pods with no credentials and no error anywhere near them. Check
   `kubectl -n pod-identity-webhook get pods` first, and remember the
   `namespaceSelector` only covers `argocd`, `vault`, `longhorn-system` and
   `security`.
3. **A stale JWKS.** Re-run `make publish-oidc`.
4. **A trailing slash on the issuer**, somewhere among the three places it is
   written. The resulting error mentions nothing about URLs.

---

## Reference

### What runs where

| Workload | ServiceAccount | Role | Grants |
|---|---|---|---|
| Vault | `vault:vault` | `cluster-vault-unseal` | Encrypt/Decrypt on the unseal CMK |
| Longhorn | `longhorn-system:longhorn-service-account` | `cluster-longhorn-backup` | R/W on the backup bucket + its key |
| Prowler | `security:prowler` | `cluster-prowler` | Write findings to the security account |

One role per workload, never one shared "cluster" role. The point of
per-service-account trust is that a compromised pod in one namespace gets that
pod's permissions and no others.

### The three ways to get AWS credentials here

There is no fourth, and `DenyIAMUsersAndKeys` at the organisation root is what
makes that true rather than aspirational.

| Who | Mechanism | Lifetime |
|---|---|---|
| Mark, at a terminal | IAM Identity Center → `aws sso login` | 1h role, 8h session |
| GitHub Actions | GitHub OIDC → `AssumeRoleWithWebIdentity` | per job |
| Pods in this cluster | Cluster OIDC issuer → `AssumeRoleWithWebIdentity` | 1h, auto-refreshed |
