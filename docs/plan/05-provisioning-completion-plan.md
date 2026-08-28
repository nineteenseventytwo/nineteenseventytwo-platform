# 05 — Provisioning completion plan

_Written 2026-08-23, against the live cluster. Supersedes nothing — it is the
join between [05-migration.md](../05-migration.md)'s "still open" list,
[06-aws-federation.md](../06-aws-federation.md)'s "still outstanding" list, and
what the cluster is actually doing right now._

The roadmap's Phase C is **built but not finished**: every Argo CD wave is
installed and the hard, one-way-door pieces (OIDC issuer, IRSA, KMS auto-unseal)
are proven working. What remains is four live defects, one security gap the
`policy/` README already claims is closed, and the whole of Phase D.

---

## Where this actually is

Verified against the cluster, not inferred from the docs.

| Thing | State | Evidence |
|---|---|---|
| Three nodes, kubeadm v1.36.4 | ✅ Ready | `kubectl get nodes` |
| Cilium, MetalLB, ingress-nginx | ✅ Synced/Healthy | LB `192.168.20.240` allocated |
| Cluster OIDC issuer + IRSA | ✅ **Proven end to end** | Vault is unsealed with `Seal Type awskms` — that only happens if the SA token → STS → KMS chain works |
| `create_jwks_bucket` / `publish_cluster_oidc` | ✅ both `true` | `live/aws/platform-prod/variables.tf` |
| Vault | ✅ initialised, unsealed, KV/k8s-auth/SSH-CA configured | `vault status`; `ca.pub` present on `1972-master-1` |
| External Secrets → Vault | ✅ 3 `ExternalSecret`s `SecretSynced` | arc-github-app, cloudflare-api-token, grafana-admin |
| SSH CA trust on nodes | ⚠️ on master, unverified elsewhere | `TrustedUserCAKeys /etc/ssh/ca.pub` in `10-hardening.conf` |
| **ARC (3 Applications)** | ❌ `Unknown` — cannot resolve chart | GHCR 403, 45h |
| **TLS certificates (3)** | ❌ `pending` 20h against **letsencrypt-prod** | Cloudflare API auth rejected |
| **Longhorn S3 backups** | ❌ `BackupTarget default AVAILABLE=false` | "could not access s3 without credential secret" |
| **Default-deny NetworkPolicy** | ❌ **5 of 19 namespaces** | see WP-2 |
| `apps/` | ⛔ empty — only `README.md` | the `100-apps` ApplicationSet has nothing to discover |
| Kubescape baseline | ⛔ never captured | `docs/baseline-nsa.json` does not exist |
| Prowler | ⛔ `enable_prowler_role = false`, no `security` namespace | |
| ADR-0010 (fork-PR runners) | ✅ **closed — verified** | zero `pull_request` triggers in any `eightbitsaxlounge` workflow |

---

## WP-1 — Unbreak what is already deployed

Do this first. Three of the four are actively failing on a loop, and one of them
is burning a rate limit.

### 1.1 ARC: the OCI source path is wrong for Argo CD 3.5

All three ARC Applications fail identically:

```
failed to resolve revision "0.14.2": cannot get digest for revision 0.14.2:
HEAD "https://ghcr.io/v2/actions/actions-runner-controller-charts/manifests/0.14.2": 403 denied
```

**This is not a bad chart version.** `0.14.2` pulls fine anonymously from a
workstation. Read the URL Argo constructed: the repository path is
`actions/actions-runner-controller-charts` — **the chart name is missing**.
Argo CD v3.5.1 is not appending `chart: gha-runner-scale-set-controller` to an
`oci://`-prefixed `repoURL`, so it asks GHCR for a repository that does not
exist, and GHCR answers 403 rather than 404 for anonymous callers.

ARC is also the only OCI source in `cluster/argocd/applications/` — every other
chart is a plain `https://` Helm repo, and every other one is Synced.

- [ ] In `80-arc-controller.yaml`, `81-arc-lab-deploy.yaml`, `82-arc-lab-dind.yaml`:
      drop the `oci://` scheme (`repoURL: ghcr.io/actions/actions-runner-controller-charts`),
      which is the form Argo CD 3.x expects for a first-class OCI repo
- [ ] If that still 403s, fold the chart into the path
      (`repoURL: oci://ghcr.io/actions/actions-runner-controller-charts/gha-runner-scale-set-controller`,
      no `chart:` key) and confirm against the constructed URL in the error, not the docs
- [ ] Re-check: `kubectl -n argocd get app | grep arc` → all three `Synced/Healthy`

### 1.2 Cloudflare API token is malformed → three certs stuck on LE **prod**

```
Error: 6003: Invalid request headers <- 6111: Invalid format for Authorization header
```

Cloudflare returns 6111 when the bearer value itself is unusable — in practice a
**trailing newline or whitespace** in the stored secret, or a Global API Key
stored where a scoped API Token belongs. The value lives in Vault at
`kv/platform/cloudflare` and ESO projects it, so ESO is doing its job correctly
and faithfully propagating a bad value.

Two things make this urgent rather than cosmetic:

1. `argocd-server-tls`, `grafana-tls` and `vault-tls` all point at
   **`letsencrypt-prod`**, not staging — the opposite of what
   [04-secrets.md §5](../04-secrets.md#5-tier-4--tls) says to do. Fifty retries
   over twenty hours are accumulating against the ACME failed-validation limit.
2. Nothing in the lab has a browser-trusted certificate until this clears.

- [ ] Pause the bleeding: switch the three `Certificate`s to `letsencrypt-staging`
      (or delete the pending `Order`s) before touching the token
- [ ] Re-store the token in Vault with no trailing newline — `printf %s` when
      writing, never `echo`; confirm it is a scoped **API Token**
      (`Zone:DNS:Edit`, single zone), not a Global API Key
- [ ] Force ESO to refresh, then confirm the challenge presents:
      `kubectl -n argocd describe challenge` → `Presented: true`
- [ ] Issue cleanly on staging, **then** flip all three back to `letsencrypt-prod`
- [ ] Record the "always staging first" rule where it will actually be seen —
      the `Certificate` manifests, not just the doc

### 1.3 Longhorn S3 backups: IRSA is not sufficient here

`BackupTarget/default` has been `AVAILABLE=false` for 22h:

```
failed to init backup target clients: could not access s3 without credential secret
```

The `longhorn-service-account` **does** carry
`eks.amazonaws.com/role-arn: .../cluster-longhorn-backup`, and `longhorn-system`
**is** in the webhook's `namespaceSelector`. But the running `longhorn-manager`
pods carry no `AWS_ROLE_ARN` at all — their env is only
`POD_NAME POD_NAMESPACE POD_IP NODE_NAME LONGHORN_DISTRO`. Two separate problems
stacked:

- The pods predate the webhook (same class of thing as the documented
  `argocd-repo-server` restart in [06 §6](../06-aws-federation.md)), so they never
  passed through injection.
- Independently, Longhorn refuses an S3 target with an empty
  `backupTargetCredentialSecret` on principle — its engine pods take credentials
  from that Secret, and for IRSA it expects an `AWS_IAM_ROLE_ARN` key inside it.
  `cluster/longhorn/values.yaml:53` sets it to `""` with a comment saying the
  webhook handles it. That assumption is wrong for Longhorn specifically.

- [ ] `kubectl -n longhorn-system rollout restart daemonset/longhorn-manager` and
      confirm `AWS_ROLE_ARN` appears — that isolates which of the two is load-bearing
- [ ] Create the credential Secret carrying `AWS_IAM_ROLE_ARN` and point
      `backupTargetCredentialSecret` at it; verify against the Longhorn version
      actually deployed (1.12.1), not a blog post
- [ ] `longhorn-system` has six per-component NetworkPolicies but **no egress rule
      to S3** — and no default-deny either (WP-2), which is currently the only
      reason this is not a third failure mode. Add the S3 egress rule *before*
      WP-2 lands default-deny here, or backups break the moment it does
- [ ] Done when `kubectl -n longhorn-system get backuptargets` shows `AVAILABLE=true`
      and one volume backup completes end to end

### 1.4 `platform` app drift — trivial

The app-of-apps is `OutOfSync` on one field: git has
`spec.source.directory.recurse: false` on the `pod-identity-webhook`
Application; the live object does not (Argo prunes the default).

- [ ] Remove the `directory:` block from `35-pod-identity-webhook.yaml`, or sync
      and let it settle. Either way, get `platform` back to `Synced` so it is a
      real signal again

### 1.5 Commit the working-tree change

`Makefile` has an uncommitted fix to `verify-irsa` (the jsonpath
`env[?(@.name=="AWS_ROLE_ARN")]` form does not work under the shell quoting;
replaced with a `grep`).

- [ ] Commit it. An uncommitted fix to a verification target is how a green
      `make verify-irsa` stops meaning anything

---

## WP-2 — Close the default-deny gap

`policy/README.md` says `10-default-deny.yaml` enforces "Default-deny ingress +
egress in **every** namespace". It does not. It covers three infra namespaces
plus the two tenants:

**Covered (5):** `argocd`, `monitoring`, `pod-identity-webhook`,
`eightbitsaxlounge-dev`, `eightbitsaxlounge-prod`

**Not covered (14):** `arc-runners`, `arc-systems`, `cert-manager`,
`cilium-secrets`, `default`, `external-secrets`, `ingress-nginx`,
`kube-node-lease`, `kube-public`, `kube-system`, `longhorn-system`,
`metallb-system`, `node-exporter-system`, `vault`

That `vault`, `external-secrets` and `cert-manager` are open is the part that
matters — those are the three namespaces holding the cluster's secrets material,
and they currently have unrestricted pod-to-pod reachability from anywhere in
the cluster.

### The order to do this in

Retrofitting default-deny onto a running namespace is exactly the "discover
which flows you broke one incident at a time" problem `policy/README.md` warns
about. The file's existing comments are a gift here — they already record, from
live `cilium monitor --type policy-verdict` evidence, that:

- the apiserver resolves to the **`kube-apiserver` reserved identity**, so
  `ipBlock` and `podSelector` never match it — `toEntities` is required
- `toEntities`/`fromEntities` **do not compose with `toPorts`** in this Cilium
  version; the rule must be unscoped by port or it denies with `match none`
- same-namespace traffic needs its own explicit `podSelector: {}` pair

Assume every namespace below needs all three, and derive the rest empirically.

- [ ] **Recommended exemptions, documented rather than silent** — add them to
      `policy/10-default-deny.yaml` as comments explaining *why*, the same way
      `00-namespaces.yaml` handles the PSS exemptions:
      `kube-system` (CoreDNS, kube-proxy, and the CNI itself — a mistake here
      takes the cluster down and Argo CD with it), `cilium-secrets`,
      `kube-node-lease`, `kube-public` (no workloads, no pods to select)
- [ ] **`default`** — lock it fully closed. Nothing should ever run there, so a
      bare `default-deny-all` with no allow-pair is both correct and free
- [ ] **`vault`** — highest value. Needs: DNS, apiserver (`toEntities`), STS/KMS
      egress to the internet on 443, ingress from `ingress-nginx` and `monitoring`,
      ingress from `external-secrets`
- [ ] **`external-secrets`** — DNS, apiserver, egress to `vault`
- [ ] **`cert-manager`** — DNS, apiserver, egress to the internet on 443
      (ACME + the Cloudflare API), ingress from `monitoring`
- [ ] **`ingress-nginx`** — ingress from the LAN (`192.168.20.0/24`) and
      `metallb-system`, egress to every namespace it fronts, DNS, apiserver
- [ ] **`longhorn-system`** — see WP-1.3; needs the S3 egress rule **first**
- [ ] **`metallb-system`** — speaker is `hostNetwork`; verify a NetworkPolicy is
      even meaningful for it before writing one, and say so in the file if not
- [ ] **`arc-systems`** / **`arc-runners`** — do these last, after WP-1.1. Runners
      need broad egress by nature; write the policy against what the runners
      actually do rather than guessing
- [ ] **`node-exporter-system`** — `hostNetwork` + `hostPort`, same caveat as
      metallb; ingress from `monitoring` on 9100 if it applies at all

### Make it a test, not an inspection

The reason this gap existed is that "every namespace has default-deny" was a
sentence in a README rather than an assertion anything ran.

- [ ] Add a check to `tests/` that enumerates namespaces and fails on any
      without a `default-deny-all`, minus an explicit exemption list
- [ ] Wire it into the lint/verify path so a new namespace cannot land uncovered
- [ ] Update `policy/README.md` so the claim matches the file
- [ ] Re-run the `03-cluster.md` verify block; `kubectl get networkpolicy -A`
      should now show `default-deny-all` in every non-exempt namespace

---

## WP-3 — Finish Phase D: secrets tiers 3 and 4

### 3.1 SSH CA cutover (Tier 3)

Further along than the docs suggest: `hardening_ssh_trust_ca` already defaults to
`true`, `bootstrap/ssh/ca.pub` is populated, and `1972-master-1` already has
`TrustedUserCAKeys /etc/ssh/ca.pub`.

- [x] Confirm all four nodes have the CA and that the deployed file matches the
      repo's `ca.pub` byte for byte — confirmed 2026-08-23, all four
- [x] Exercise `bootstrap/ssh/sign.sh 192.168.20.202` — a real 5-minute
      certificate login, not a key login that happens to still work —
      confirmed 2026-08-23 with the initial root token (see 3.3's new item on
      that — no scoped signing policy exists yet)
- [x] Confirm the break-glass static key on `1972-console-1` is present, offline,
      and documented — confirmed 2026-08-23: passphrase-protected (verified it
      rejects a wrong/empty passphrase), `bootstrap/ssh/break-glass.pub`
      committed and matches console's live `authorized_keys` byte-for-byte,
      private key removed from the workstation
- [x] **Retire `ansible-console` and `ansible-workstation` from
      `authorized_keys`** — done 2026-08-28. `hardening_ssh_retire_legacy_keys:
      true`, `make deploy-nodes` run for real: `master`/`worker-1`/`worker-2`
      now have empty `authorized_keys`, `console` has `break-glass` as its
      only static entry. Verified with all four `sign.sh` targets connecting
      cleanly post-cutover, not just the ansible run reporting success.
      `wait_for_connection`'s own post-task failed with `Permission denied` on
      all four — expected, not a fault: it authenticates with
      `ansible-workstation`, the key the same run had just retired, so of
      course a fresh connection with it fails now
- [x] **Found immediately after, running the cutover itself; closed same
      day**: nothing signed a certificate over `ansible-workstation`'s
      keypair the way `sign-ci.sh` does for `ansible-console`'s, so
      `make deploy-nodes`/`deploy-cicd` run from a workstation had no
      working default `SSH_KEY`. Closed without a third script:
      `bootstrap/ssh/sign.sh`'s `HOST` argument is now optional — with
      none, it signs and exits rather than connecting — and `make sign-ws`
      wraps that against `ansible-workstation`, prompting for a Vault token
      the same way `make ssh-ws` already does. `make sign-ws` then
      `make deploy-nodes` works with no further changes, since the
      Makefile's `SSH_CERT` wildcard mount already existed. Also fixed in
      the same pass: `sign.sh`'s `> "$CERT"` truncated its target before
      `vault write` ran, so a failed sign left a real 0-byte cert file
      behind — harmless when the script's only failure mode was "fail
      loudly in front of you," a live landmine once sign-only mode meant
      the file was meant to outlive the script. Fixed with mktemp + trap +
      mv; confirmed live that a second failed attempt leaves nothing behind.
- [ ] **Found while testing sign.sh, and again while testing sign-ci.sh**:
      none of `argocd.`/`vault.`/`grafana.eightbitsaxlounge.com` resolve
      from either VLAN 10 or `1972-console-1`, despite
      `01-network-validation.md` explicitly calling for Unbound host
      overrides for all three. Second time affected CI's own certificate
      signing directly, not just browser/CLI convenience — a compose-level
      `extra_hosts` workaround was tried and deliberately reverted in favour
      of fixing the actual gap, since it only helped the one consumer.
      `tests/network-check.sh 12` now checks this and
      `01-network-validation.md` gives the exact three Host-record values —
      **adding them on OPNsense is still the one action item left here**

### 3.2 TLS (Tier 4) — follows WP-1.2

- [x] Staging issues cleanly → production for all three hosts — done in PR
      #44. Confirmed live: all three (`argocd`/`vault`/`grafana`) show
      `Ready: True` with `issuer=O=Let's Encrypt, CN=YR1` — real
      production, not staging
- [x] Confirm the `internal-ca` ClusterIssuer path still works — `Ready: True`

### 3.3 The remaining secret-hygiene items

- [ ] `sops updatekeys` on `ansible/inventory/lab/group_vars/all/secrets.sops.yml`
      and every other encrypted file — adding the KMS recipient to `.sops.yaml`
      did **not** rewrite them, so the cluster cannot decrypt anything encrypted
      before that change
- [ ] **Retire the `KUBECONFIG` org secret.** Both `04-secrets.md`'s verify block
      and the inventory call for this. It is the last broadly-scoped static
      credential in GitHub
- [ ] **Decide the Argo CD SOPS plugin question.** `cluster-argocd-sops` and the
      `repoServer` annotation exist, nothing in `cluster/` is SOPS-encrypted, and
      no plugin is configured. Either land the plugin and use it, or delete the
      role — a role with no consumer is a standing grant that nothing tests
- [ ] Confirm the only remaining GitHub secrets are `SOPS_AGE_KEY` and the
      GitHub App key
- [ ] **Write a scoped Vault policy for SSH signing.** Found 2026-08-23,
      confirming `bootstrap/ssh/sign.sh` for real: `vault policy list` shows
      only `default`, `external-secrets`, and `root` — no policy was ever
      created for the human's day-to-day `ssh-client-signer/sign/admin`
      calls, so the initial root token is currently the *only* credential
      that can run `sign.sh` at all. Works for testing, but "use root to
      SSH in" defeats some of the point of Vault-issued certs. Add something
      like `path "ssh-client-signer/sign/admin" { capabilities = ["create",
      "update"] }`, attached to a real auth method (Vault's `userpass`, not
      another static token) rather than a second token to manage

---

## WP-4 — AWS / cloud repo

- [ ] **Prowler** — create the `security` namespace and the CronJob, then flip
      `enable_prowler_role = true`. It is gated separately from
      `publish_cluster_oidc` precisely so it can go last. Note the webhook's
      `namespaceSelector` already lists `security`, so the namespace name is fixed
- [ ] **Widen the staged SCPs.** `DenyRegionsOutsideAllowlist` and
      `DenyExpensiveResources` are attached to the sandbox account only. Follow
      `policies/README.md`'s own rollout order: sandbox account → OU → root, with
      a week of CloudTrail between steps watching for unexpected `AccessDenied`
- [ ] **Strike the stale TODO in `nineteenseventytwo-cloud/README.md`.** It says
      `cluster/vault/values.yaml` "passes `AWS_ACCESS_KEY_ID` to Vault". It does
      not — that Secret is gone and the SA annotation replaced it. Leaving a
      resolved item in a TODO list is how the list stops being read
- [ ] Re-run `make output STACK=platform-prod` and cross-check `cluster_role_arns`
      against `aws_cluster_role_arns` in the inventory and the annotations in
      `cluster/*/values.yaml` — [06 §5](../06-aws-federation.md) asks for this and
      it has not obviously been done since the roles landed

---

## WP-5 — The migration (05-migration.md)

This is the largest remaining block and it has not started. `apps/` contains a
README and nothing else, so the `100-apps` ApplicationSet is reconciling an empty
set — the tenant namespaces, quotas and LimitRanges exist and hold nothing.

- [ ] **Record ADR-0010 as closed.** `05-migration.md` says "confirm closed, don't
      assume it from this doc" — confirmed: no `eightbitsaxlounge` workflow has a
      `pull_request` trigger at all. Write that into the doc with today's date so
      nobody re-audits it
- [ ] Verify every remaining chart pin before its next apply
      (`helm search repo <chart> --versions`) — WP-1.1 is the first casualty of
      this item and probably not the last
- [ ] Migrate the six services **one at a time**, verifying each before the next,
      per `apps/README.md`: `db-couchdb` → `state-nats` → `chat` → `midi-api` →
      `security` → `overlay`. Each needs its `image:` repointed at GHCR, requests
      sized to fit the ResourceQuota, and every Secret converted to an
      `ExternalSecret` against `kv/tenants/eightbitsaxlounge/*`
- [ ] Every one of the old repo's workflows is `runs-on: self-hosted` against the
      retiring runner. Decide per workflow: repoint at the ARC scale set (after
      WP-1.1), move to hosted, or delete. The `midi-data-*` and `chat-set-environment`
      ones are runtime operations that `05-migration.md` says stay in the app repo —
      they still need a runner that exists
- [ ] Replace `server/README.md` with a stub pointing at `docs/`
- [ ] Work the mapping table to zero, then delete `eightbitsaxlounge/server`

---

## WP-6 — Evidence and rehearsal

- [ ] **The Kubescape baseline window has closed.** `03-cluster.md` step 5 says to
      scan the *empty* hardened cluster; it is now full. Either scan now and label
      it honestly as a post-install baseline, or defer it to the next rebuild and
      say so in the doc. Do not quietly scan a loaded cluster and file it as the
      "before" — the before/after pair is the whole point
- [ ] **Rehearse the rebuild.** `05-migration.md`'s definition of done requires a
      full end-to-end run: imaging → `deploy-nodes` → `deploy-cicd` →
      `deploy-cluster` → `bootstrap-argocd`. Nothing else in this plan proves the
      README's central claim, and WP-1 is four pieces of evidence that first
      contact finds things review does not
- [ ] Add the JWKS republish step to the rotation checklist next to the SSH CA —
      rotating the SA signing key without `make publish-oidc` invalidates every
      projected token in the cluster instantly

---

## WP-7 — `nineteenseventytwo-composer` divergence (low priority)

Out of scope for the platform repo per
[ADR-0011](../decisions/ADR-0011-arm64-only.md), but `composer/infra/README.md`
still documents the pre-migration world: `192.168.68.0/24` addressing, Flannel,
and a cluster "managed by the `eightbitsaxlounge/server` layer" that is being
deleted. The GPU node genuinely is out of scope; the stale description of a
cluster that no longer exists is not.

- [ ] Correct the addressing and CNI references, or add a banner stating the GPU
      track is deliberately not on VLAN 20 / not in the kubeadm cluster
- [ ] Decide whether `setup-tailscale.yaml` (deferred in the mapping table) is the
      answer for GPU-node reachability, and record it as an ADR either way

---

## Suggested order

1. **WP-1** — four live defects, all small, one burning a rate limit
2. **WP-2** — the security gap, and the one thing explicitly asked for
3. **WP-3** — Phase D closes; the `ansible-*` key retirement is the milestone
4. **WP-4** — cloud-side, independent of the above, can run in parallel
5. **WP-5** — the long tail; needs WP-1.1 and WP-3 landed first
6. **WP-6** — the rehearsal is what turns all of it into a claim you can defend
