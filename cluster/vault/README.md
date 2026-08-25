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

```bash
# 6. AppRole for CI's SSH signing (Phase D automation). CI (deploy-nodes.yml,
# deploy-cluster.yml) runs from 1972-console-1, deliberately outside the
# cluster (ADR-0007) — Kubernetes auth, what ESO uses, only works for a pod
# in *this* cluster, so it's the wrong tool here. AppRole is what Vault's own
# docs recommend for exactly this: a trusted, non-human, non-Kubernetes
# client. secret_id_bound_cidrs pins it to console's own static address, so a
# copy of this credential is useless from anywhere else.
vault auth enable approle

vault policy write ci-ssh-signer - <<'POLICY'
path "ssh-client-signer/sign/admin" { capabilities = ["create", "update"] }
POLICY

vault write auth/approle/role/ci-ssh-signer \
  token_policies="ci-ssh-signer" \
  token_ttl=5m \
  token_max_ttl=10m \
  secret_id_bound_cidrs="192.168.20.201/32" \
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
sudo install -o mchellmer -g docker -m 0640 /dev/stdin ~/.ssh/vault-ci-role-id <<< "<role_id output above>"
sudo install -o mchellmer -g docker -m 0640 /dev/stdin ~/.ssh/vault-ci-secret-id <<< "<secret_id output above>"
```

`group: docker, mode: 0640` matches `ansible-console`'s own key exactly, for
the same reason (see the comment on that key's generation task in
`20-cicd-host.yml`): CI reads both files from *inside* the containerized
runner, a sibling container over the shared docker socket, and only
docker-group membership bridges that identity gap.

`secret_id_num_uses=0` and `secret_id_ttl=0` mean this credential doesn't
expire on its own — the CIDR binding is the primary control. Rotate it the
same way the age key gets rotated: annually, or immediately on suspicion
(`vault write -f auth/approle/role/ci-ssh-signer/secret-id` mints a new one;
`vault write auth/approle/role/ci-ssh-signer/secret-id-accessor/destroy
secret_id_accessor=<accessor>` kills the old one independently).

## Break-glass

Keep one static SSH key on `1972-console-1`, offline, for when Vault is the thing
that is down. It is the only `authorized_keys` entry that survives the CA
cutover, and it is deliberate.
