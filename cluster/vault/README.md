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

# 2. Audit device. Without it there is no record of who read what.
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

## Break-glass

Keep one static SSH key on `1972-console-1`, offline, for when Vault is the thing
that is down. It is the only `authorized_keys` entry that survives the CA
cutover, and it is deliberate.
