# Vault

Tier 2 of the secrets model — cluster workload secrets. Tier 0 (SOPS+age) is
what gets Vault itself off the ground.

## Why KMS auto-unseal

Vault OSS seals on every restart and needs unseal keys to come back. A Pi
cluster reboots — for kernel updates, for power, because you moved a switch —
and every one of those becomes a manual unseal at whatever hour it happens.
AWS KMS auto-unseal removes the human from that loop for a few pence a month.

The tradeoff, stated honestly: the cluster's secrets are now unavailable if AWS
KMS is unavailable or the IAM role is revoked. That is a real dependency
on a cloud provider inside an on-prem lab. It is the right trade here because
the alternative is not "no dependency", it is "a dependency on you being awake".

## No AWS credential

Vault holds no access key. The `eks.amazonaws.com/role-arn` annotation on its
ServiceAccount is the entire AWS configuration: the pod-identity-webhook turns
it into a projected token and `AWS_ROLE_ARN` at admission, and Vault's own SDK
exchanges that at STS for an hour of access to exactly the unseal CMK.

This used to be an `AWS_ACCESS_KEY_ID` pair in a `vault-kms` Secret. That Secret
no longer exists and must not come back — `DenyIAMUsersAndKeys` at the
organisation root makes creating the key it wanted impossible anyway. See
[docs/06-aws-federation.md](../../docs/06-aws-federation.md).

If Vault will not unseal, check `kubectl -n pod-identity-webhook get pods`
before anything else: the webhook fails open, so a pod that missed injection
looks completely normal until it tries to reach AWS.

## Post-install, once

Neither of these can be set in Helm values.

```bash
kubectl -n vault exec -it vault-0 -- sh

# 1. Initialise. Recovery keys are NOT unseal keys — with auto-unseal they are
#    only used for `vault operator generate-root` and rekey. Store them in your
#    password manager, split across two entries, and never in this repo.
vault operator init -recovery-shares=3 -recovery-threshold=2

# 2. Audit device. Without it there is no record of who read what. Token output from above
vault login <initial-root-token>
vault audit enable file file_path=/vault/audit/audit.log

# 3. Kubernetes auth for ESO.
vault auth enable kubernetes
vault write auth/kubernetes/config \
  kubernetes_host="https://kubernetes.default.svc:443"
vault policy write external-secrets - <<'POLICY'
path "kv/data/platform/*"    { capabilities = ["read"] }
path "kv/data/tenants/*"     { capabilities = ["read"] }
POLICY
vault write auth/kubernetes/role/external-secrets \
  bound_service_account_names=external-secrets \
  bound_service_account_namespaces=external-secrets \
  policies=external-secrets ttl=1h

# 4. KV v2 mount, then load the bootstrap secrets from SOPS.
vault secrets enable -path=kv -version=2 kv
```

Decrypt the SOPS file on your workstation first — this shell has no sops/age,
and shouldn't:

```bash
sops -d ansible/inventory/lab/group_vars/all/secrets.sops.yml
```

Then, back inside the vault pod shell, paste the decrypted values into the
three loads below. Every path and property name here is pinned by an
`ExternalSecret`'s `remoteRef` (`cluster/*/externalsecret-*.yaml`) — if you
rename a key on either side without the other, ESO's error just says the
property wasn't found, not which of the two moved. There is no command that
does this load for you; that gap is exactly what let `cloudflare_api_token`
ship to Vault as the SOPS example file's literal `"..."` placeholder on the
first rebuild of this cluster — the KV mount succeeded, so nothing looked
unfinished, and cert-manager only exposed it 20 hours later, as a Cloudflare
API rejection with no obvious connection back to this step.

```bash
vault kv put kv/platform/github-app \
  app_id="<github_app_id>" \
  installation_id="<github_app_installation_id>" \
  private_key="<github_app_private_key>"

vault kv put kv/platform/cloudflare \
  api_token="<cloudflare_api_token>"
```

Grafana's admin credentials are Tier-2-native — generated here, not carried
through SOPS, since nothing before Vault exists needs them:

```bash
vault kv put kv/platform/grafana \
  admin-user="admin" \
  admin-password="$(openssl rand -base64 24)"
```

Alertmanager's Slack receiver (`cluster/monitoring/externalsecret-slack-alerts.yaml`)
reads from here too — missed on build 0002, where nothing surfaced it until
Alertmanager was already `CreateContainerConfigError` on a missing secret
mount, hours after this step. Not carried through SOPS for the same reason as
Grafana's password isn't: the webhook URL is a bearer credential for wherever
it posts, and this repo is public.

```bash
vault kv put kv/platform/slack-alerts \
  webhook_url="<slack incoming webhook url>"
```

This is separate from the org-level GitHub Actions secret `SLACK_WEBHOOK_URL`
(`image-vuln-scan.yml`'s weekly report) — same underlying webhook is fine to
reuse, but the two are read by different systems and neither substitutes for
the other.

Back in the same vault pod shell from step 4:

```bash
# 5. SSH CA (Tier 3).
vault secrets enable -path=ssh-client-signer ssh
vault write ssh-client-signer/config/ca generate_signing_key=true
vault write ssh-client-signer/roles/admin -<<'ROLE'
{
  "algorithm_signer": "rsa-sha2-256",
  "allow_user_certificates": true,
  "allowed_users": "mchellmer",
  "default_extensions": {"permit-pty": ""},
  "key_type": "ca",
  "default_user": "mchellmer",
  "ttl": "5m0s"
}
ROLE
vault read -field=public_key ssh-client-signer/config/ca
```

Put that last public key at `bootstrap/ssh/ca.pub`, set
`hardening_ssh_trust_ca: true`, and re-run `make deploy-nodes`.

**Prerequisite for step 6, easy to have skipped**:
`vault.eightbitsaxlounge.com` has to actually resolve from
`1972-console-1` before `sign-ci.sh` can reach Vault at all. Nothing
enforces this earlier in the sequence, and it fails silently until CI
tries to sign a certificate. Check it —

```bash
tests/network-check.sh 12
```

— and if it fails, the fix is on OPNsense, not in this repo: add the three
Unbound host overrides in
[docs/01-network-validation.md](../../docs/01-network-validation.md#opnsense-rules-this-implies),
then re-run the check above before continuing.

```bash
# 6. AppRole for CI's SSH signing (Phase D automation). CI (deploy-nodes.yml,
# deploy-cluster.yml) runs from 1972-console-1, deliberately outside the
# cluster (ADR-0007) — Kubernetes auth, what ESO uses, only works for a pod
# in *this* cluster, so it's the wrong tool here. AppRole is what Vault's own
# docs recommend for exactly this: a trusted, non-human, non-Kubernetes
# client.
#
# secret_id_bound_cidrs is the cluster's pod network, not console's own
# address — corrected 2026-08-27 after live testing, not assumed. Console has
# no network path to Vault that preserves its own IP: it can only reach Vault
# through whatever fronts the public hostname (ingress-nginx originally,
# the shared Gateway since ADR-0015), and that reverse-proxy hop replaces the
# source address with its own pod IP before vault-0 ever sees the request —
# confirmed live as "source address 10.244.1.100 unauthorized by CIDR
# restrictions" against the console-specific /32 this originally shipped
# with. Re-confirmed after the Gateway cutover (2026-09-02) via `hubble
# observe --namespace vault`: the TCP-layer peer address Cilium's Gateway
# data plane presents to vault-0 is also a 10.244.0.0/16 address
# (10.244.1.96 at test time) - same pod-network range, no change needed
# here. Binding to console specifically is not achievable over this network
# path; the primary protection is the attached policy, scoped to exactly
# ssh-client-signer/sign/admin and nothing else. A leaked secret_id, even
# from inside the cluster's own pod network, can only ever request a
# 5-minute cert for mchellmer — never broader.
vault auth enable approle

vault policy write ci-ssh-signer - <<'POLICY'
path "ssh-client-signer/sign/admin" { capabilities = ["create", "update"] }
POLICY

vault write auth/approle/role/ci-ssh-signer \
  token_policies="ci-ssh-signer" \
  token_ttl=5m \
  token_max_ttl=10m \
  secret_id_bound_cidrs="10.244.0.0/16" \
  secret_id_num_uses=0 \
  secret_id_ttl=0

vault read -field=role_id auth/approle/role/ci-ssh-signer/role-id
vault write -field=secret_id -f auth/approle/role/ci-ssh-signer/secret-id
```

Neither output value goes in this repo, in SOPS, or in a GitHub secret —
same reasoning as `ansible-console`'s own key just above: this is a
machine-to-machine credential for a host that already holds one, not a
bootstrap secret Vault gets seeded from. Place them directly on console:

```bash
ssh mchellmer@192.168.20.201
sudo install -o github-runner -g github-runner -m 0444 /dev/stdin \
  /opt/github-runner/vault-ci/role-id <<< "<role_id output above>"
sudo install -o github-runner -g github-runner -m 0444 /dev/stdin \
  /opt/github-runner/vault-ci/secret-id <<< "<secret_id output above>"
```

**Not `~/.ssh/`.** `sign-ci.sh` runs *inside* the runner container, which
mounts `/opt/github-runner/vault-ci` (read-only) and does not mount
`/home/mchellmer/.ssh` — deliberately, since signing needs only the public
half of `ansible-console`'s keypair and the private key has no business in
that container. `make deploy-cicd` creates this directory and drops
`ansible-console.pub` into it; the two files above are the only part done by
hand.

Mode `0444`, not `0400` — confirmed live, not assumed: the runner process is
uid 1001 (the base image's own fixed `runner` user), which lines up with
neither `github-runner`'s host uid nor its group. `0400` left the container
unable to read either file at all. Same mismatch `github-app.pem`'s own task
documents, and the same trade: the files are world-readable inside a
single-tenant container, but the directory's own mode (`0751`, set by the
`runner_host` role) still blocks anyone who isn't the owner from listing
what's in it — traversal to a named file, not disclosure of what files
exist. Owned by `github-runner:github-runner` for consistency with the rest
of this directory, even though the actual reading process is neither that
user nor in that group; unlike `ansible-console`'s own key, this is read
directly by the runner container itself, not a sibling over the docker
socket, so the docker-group trick in `20-cicd-host.yml` doesn't apply here.

`secret_id_num_uses=0` and `secret_id_ttl=0` mean this credential doesn't
expire on its own — the CIDR binding is the primary control. Rotate it the
same way the age key gets rotated: annually, or immediately on suspicion
(`vault write -f auth/approle/role/ci-ssh-signer/secret-id` mints a new one;
`vault write auth/approle/role/ci-ssh-signer/secret-id-accessor/destroy
secret_id_accessor=<accessor>` kills the old one independently).

```bash
# 7. userpass auth for the human's own day-to-day SSH signing. Found live
# 2026-08-23, confirming bootstrap/ssh/sign.sh for real: `vault policy list`
# showed only `default`, `external-secrets` and `root` — nothing scoped had
# ever been created for exactly this, so the initial root token was the
# *only* credential that could run sign.sh at all. Works for testing, but
# "use root to SSH in" defeats a chunk of the point of Vault-issued certs.
vault auth enable userpass

vault policy write ssh-human-signer - <<'POLICY'
path "ssh-client-signer/sign/admin" { capabilities = ["create", "update"] }
POLICY

# 1h/8h mirrors the AWS SSO session shape already used elsewhere in this
# repo (docs/04-secrets.md's secret inventory: "1h role, 8h session") rather
# than inventing a new convention for the same kind of thing.
vault write auth/userpass/users/mchellmer \
  policies="ssh-human-signer" \
  token_ttl=1h \
  token_max_ttl=8h \
  password=-
```

That last line's value ("-") tells `vault write` to read just that one field
from stdin — type the password and Ctrl-D, and it never touches shell
history or a process listing. Log in with it once per session, instead of
the root token:

```bash
vault login -method=userpass username=mchellmer
```

`bootstrap/ssh/sign.sh` needed no code change for this — it has never
handled authentication itself, only signing; it just uses whatever
`VAULT_TOKEN` or `~/.vault-token` a prior `vault login` already left behind.
The gap was entirely on the Vault-config side: there was nothing scoped to
actually log in *as*, so root was the only option by omission, not by
design.

**`make sign-ws` is the one exception** — its own prompt (`if [ -z
"$VAULT_TOKEN" ]; then read -s -p "Vault token: " ...`) checks the
*environment variable* specifically, not `~/.vault-token`, because the
signing itself runs inside a container that only gets what's explicitly
passed through. `vault login` alone leaves you re-typing the same token into
that prompt. Export it into the shell once after logging in and every
`make sign-ws` in that session skips the prompt:

```bash
vault login -method=userpass username=mchellmer
export VAULT_TOKEN=$(vault print token)
make sign-ws
```

The root token still works after this — Vault policies are additive, not
exclusive — but should stop being the thing reached for day to day now that
a properly scoped alternative exists. Keep it for what it's actually for:
`generate-root`, rekey, and emergencies, per the recovery-keys row in
[docs/04-secrets.md](../../docs/04-secrets.md#secret-inventory).

## Break-glass

Keep one static SSH key on `1972-console-1`, offline, for when Vault is the thing
that is down. It is the only `authorized_keys` entry that survives the CA
cutover, and it is deliberate.
