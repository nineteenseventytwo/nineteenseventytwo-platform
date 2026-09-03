# policy/

Cluster-scoped guardrails. Applied once by `ansible/playbooks/30-cluster.yml`
(so the cluster is never briefly open) and reconciled thereafter by the
`platform-policy` Argo CD Application (so it stays that way).

| File | What it enforces |
|---|---|
| `00-namespaces.yaml` | Infra namespaces with their Pod Security Standards labels |
| `10-default-deny.yaml` | Default-deny ingress + egress in every namespace that carries workloads, with the DNS exception. Exemptions (CNI/DNS-critical namespaces, and hostNetwork-only ones where standard NetworkPolicy isn't enforced) are documented at the top of the file. |
| `20-limitrange-default.yaml` | A default request/limit so an unspecified pod cannot claim a whole node |
| `30-prowler.yaml` | The `security` namespace's ServiceAccount + CronJob, scheduled Prowler scans against the whole AWS account |
| `tenants/*.yaml` | Per-app namespace + ResourceQuota + LimitRange + ServiceAccount + Role |

## Why default-deny goes in first

Retrofitting default-deny onto a running cluster means discovering which flows
you broke one incident at a time. Applying it to an empty cluster means every
allow-pair is added deliberately, by the team that needs it, in a PR.

Cilium enforces this. Flannel could not, which is the practical reason for the
CNI swap — see [ADR-0003](../docs/decisions/ADR-0003-cni-cilium-no-mesh.md).

## The tenant contract

`platform` creates the namespace, quota and RBAC. The app repo gets a
kubeconfig for a ServiceAccount that can act **only** in its own namespace, and
its pipeline uses that. It cannot create namespaces, cannot touch cluster-scoped
resources, and cannot exceed its quota. `bootstrap/tenant-kubeconfig/generate.sh`
turns the ServiceAccount into that kubeconfig and publishes it to Vault.

ResourceQuota matters more than it sounds on 2 GB nodes: one runaway Deployment
should not be able to evict Prometheus.

Adding a tenant is a PR here. Copy `tenants/eightbitsaxlounge.yaml`, change the
names, and follow the kubeconfig instructions at the bottom of that file.

---

# Findings

## Prowler

### Region filter, or it OOMKills

Confirmed live 2026-08-28: with no `--region` filter, Prowler scans **every
enabled AWS region by default** (39 of them) and OOMKilled twice at a 1Gi limit.
The account only ever uses the two in `config/aws.json`'s `regions.allowed`
(`nineteenseventytwo-cloud`). Scanning regions this account never touches was
pure waste, not a safety margin. The 2Gi limit is generous headroom above the
two-region footprint, not sized to the 39-region scan it replaced.

### --output-directory must be a bare relative name

Prowler's S3 key mapping (`get_object_path` in
`providers/aws/lib/s3/s3.py`) strips everything up to and including the first
literal `prowler/` substring in `--output-directory` before using the rest as the
S3 key prefix. **Every path under this image's own home directory contains that
substring**, so the original absolute path silently uploaded to
`<bucket>/output/findings/*` instead of `<bucket>/findings/*` — a full prefix
mismatch against the bucket policy's exact-match IAM condition.

That produced a bare `AccessDenied` which `send_to_bucket`'s own try/except only
ever sends to Prowler's logger, never stdout. Confirmed by reading the method
directly inside the pinned image, and separately by the bucket staying empty.

A relative `findings` avoids the substring entirely and resolves under the
`WorkingDir` (`/home/prowler`), where the `volumeMount` places the same
`emptyDir`.

### --output-bucket needs --output-formats

`--output-bucket`'s own `--help` is explicit that it requires `-M <mode>`.
Confirmed the hard way: without it, local files were written (Prowler's default
formats) but nothing reached S3 at all, and no error either.

### exit 3 is success

Prowler's documented behaviour: exit 3 means "the scan ran fine and found FAIL
results", not a crash — normal for basically every real account, every day.
Findings are the output this Job exists to produce. Without `--ignore-exit-code-3`
the Job and its Pod read as failed on every non-empty run, and a real crash would
look identical.

### uid 1000 is not negotiable

`prowlercloud/prowler` hardcodes uid 1000 and chmods `/home/prowler` 700.
Confirmed empirically: `podman run --user 10000:10000` on this same image fails
to even exec the entrypoint with `Permission denied` before Prowler's own code
runs, because nothing but uid 1000 can traverse into its home directory. A high,
host-conflict-avoiding UID would need a derivative image — a bigger investment
than a third-party scanner CronJob warrants. Hence the scoped `CKV_K8S_40` skip.

### Its own namespace is deliberate

`security` exists (`00-namespaces.yaml`) rather than reusing an existing
namespace specifically so the broad 443 egress in `10-default-deny.yaml`'s
`allow-security-prowler` rule is contained to exactly this workload.

The role is read-everything, write-one-prefix: `SecurityAudit` +
`ViewOnlyAccess` for reads, and `s3:PutObject` under `<bucket>/findings/*` as its
only write. A posture scanner that can change posture is a posture problem.
