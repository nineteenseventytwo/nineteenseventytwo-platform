# 04 — Secrets

There is a bootstrapping order here, and getting it wrong is how people end up
with Vault credentials in GitHub secrets protecting the Vault that holds the
credentials.

## The layers

| Tier | Problem | Tool | Root of trust |
|---|---|---|---|
| 0 | Config secrets before anything exists | **SOPS + age** | age private key: password manager, a GitHub Actions secret, and `/root/.config/sops/age/keys.txt` on console |
| 1 | CI → AWS | **GitHub OIDC → IAM role** | Nothing stored. Trust policy pins the org and repo. |
| 1b | CI → GitHub (runner registration) | **GitHub App private key** | SOPS-encrypted + org secret |
| 2 | Cluster workload secrets | **Vault OSS** + **External Secrets Operator** | Vault, auto-unsealed by AWS KMS |
| 3 | SSH access | **Vault SSH secrets engine (CA)** | Vault |
| 4 | TLS | **cert-manager** + Let's Encrypt DNS-01 | Cloudflare API token, held in Vault |

## Secret inventory

The single most interview-legible artefact in the repo, and it takes twenty
minutes to maintain. Every secret, where it lives, what it reaches, how often it
rotates, and what happens if it leaks.

| Secret | Lives | Reaches | Rotation | Blast radius if leaked |
|---|---|---|---|---|
| `age` private key | Password manager; `SOPS_AGE_KEY` org secret; console `/root/.config/sops/age/keys.txt` | Every Tier-0 value in this repo | Annual, or immediately on suspicion | **Total for Tier 0** — GitHub App key, Cloudflare token, KMS creds. Rotate by re-encrypting with a new recipient and revoking the old. |
| GitHub App private key | SOPS + org Actions secret | Org runner registration | Annual | Attacker can register runners into the org and receive jobs. Revoke in App settings; regeneration is instant. |
| `ANSIBLE_SSH_KEY` | Org Actions secret; console | All four Pis as `mchellmer` | Annual → **retired at Phase D** | Root-equivalent on every node (NOPASSWD sudo). The reason Tier 3 exists. |
| `ANSIBLE_KNOWN_HOSTS` | Org Actions secret | — | On node reimage | Not secret; pinned so `host_key_checking` is meaningfully on. |
| etcd encryption key | `/etc/kubernetes/enc/` on `1972-master-1`, mode 0600 | Every Secret in the cluster at rest | Manual rekey (rewrites every Secret) | Reads every cluster Secret from an etcd snapshot or a stolen SSD. **Back it up with the etcd snapshot, not instead of it — losing it makes every Secret unreadable.** |
| Vault recovery keys | Password manager, split across two entries | `generate-root`, rekey | On personnel change | Full Vault takeover via root token generation. Not unseal keys — auto-unseal is KMS. |
| AWS KMS key / IAM principal | AWS; creds in `vault-kms` Secret | Vault's seal | Quarterly (IAM keys); KMS key never | Vault cannot unseal if revoked; cannot be decrypted without it if stolen alone. |
| Cloudflare API token | Vault `kv/platform/cloudflare` | `Zone:DNS:Edit` on one zone | Semi-annual | DNS records for one zone — enough to mis-issue certificates for it. Scope to the single zone, never account-wide. |
| App secrets (env vars, API keys) | Vault `kv/tenants/<name>/*` | One namespace each, via `ExternalSecret` | Per-app | Whatever that app's config holds. No app repo can read another's — see [ADR-0012](decisions/ADR-0012-platform-owns-app-workloads.md); there is no tenant kubeconfig anymore, only this. |
| Grafana admin password | Vault `kv/platform/grafana` | Grafana | Annual | Dashboards and datasource credentials. |
| Break-glass SSH key | Offline, on `1972-console-1` | All nodes | Never (audited) | Root-equivalent. Exists precisely for when Vault is the thing that is down. |

## Tier 0 — SOPS + age, and retiring ansible-vault

`sops` + `age`, not `ansible-vault` ([ADR-0008](decisions/ADR-0008-sops-age.md)):

- Encrypts **values, not files** — `git diff` stays readable, so a playbook
  change can be reviewed without decrypting it.
- Multiple recipients (your key + a CI key) with no shared password.
- Works on Kubernetes manifests and Helm values too, so it is one tool across
  the GitOps layer. `ansible-vault` only ever helps Ansible.
- `age` keys are small and easy to rotate, unlike a shared vault password that
  has been pasted into three places.

```bash
age-keygen -o ~/.config/sops/age/keys.txt      # note the public key
# put both public keys in .sops.yaml, then
cp ansible/inventory/lab/group_vars/all/secrets.sops.yml{.example,}
sops --encrypt --in-place ansible/inventory/lab/group_vars/all/secrets.sops.yml
```

`.sops.yaml` ships with placeholder recipients. SOPS refuses to encrypt against
a malformed recipient rather than silently producing a file only one party can
read, so the placeholders are inert until replaced.

## Tier 2 — Vault, and the unseal problem nobody mentions

Vault OSS **seals itself on every restart**. On a Pi cluster that reboots, that
means hand-unsealing at 11pm. **AWS KMS auto-unseal** removes the manual step
for pennies a month, and exercises KMS key policy along the way.

Stated honestly: this makes an on-prem cluster's secrets depend on a cloud KMS.
That is a real dependency. It is the right trade because the alternative is not
"no dependency" — it is "a dependency on you being awake".

Pair Vault with **External Secrets Operator**, not the Vault CSI driver or the
Agent injector. An `ExternalSecret` materialises an ordinary Kubernetes Secret,
so app manifests carry no Vault-specific annotations, and the same manifest can
point at AWS Secrets Manager when a workload moves to the cloud. That
backend-swap property is the whole argument.

### Why the bootstrap order is not circular

1. SOPS+age holds the bootstrap secrets. No cluster required.
2. Argo CD installs ESO and Vault. Vault auto-unseals from KMS — nothing waits
   on a human.
3. Vault is populated from the SOPS values, **once**, by hand.
4. Everything else reads from Vault via `ExternalSecret`.

ESO authenticates to Vault with its ServiceAccount token via Vault's Kubernetes
auth — so there is no static Vault credential stored anywhere, which is exactly
the trap this section opened with.

Post-install commands are in [`cluster/vault/README.md`](../cluster/vault/README.md).

## Tier 3 — SSH certificates

What Phase A ships are SSH **keys**. A real SSH CA signs short-lived
**certificates**, so nodes trust the CA rather than a list of keys.

1. Enable the SSH secrets engine; configure a CA and an `admin` role
   (`allowed_users`, `ttl: 5m`, `default_extensions: permit-pty`).
2. Ansible drops the CA public key on every Pi and sets `TrustedUserCAKeys` in
   `sshd_config` — set `hardening_ssh_trust_ca: true` and re-run
   `make deploy-nodes`.
3. `bootstrap/ssh/sign.sh 192.168.20.202` signs your key into a 5-minute
   certificate and connects with it.

What this buys: no `authorized_keys` to manage or drift, revocation that
actually works, an audit log of who requested access to what and when, and
credentials that expire before you have finished making tea. It is the on-prem
mirror of the short-lived-credential pattern `aws configure sso` gives you.

Keep **one** break-glass static key on `1972-console-1`, offline, for when Vault
is the thing that is down.

## Tier 4 — TLS

cert-manager + Let's Encrypt via **DNS-01 through Cloudflare**. DNS-01 is the
important choice: it issues browser-trusted certificates for services with **no
inbound internet path at all**, which is exactly this situation. HTTP-01 would
require exposing port 80 from VLAN 20 to the internet — the thing the entire
network design avoids.

The Cloudflare token is scoped `Zone:DNS:Edit` on the single zone, stored in
Vault, and projected into the `cert-manager` namespace by ESO.

Exercise `letsencrypt-staging` first. Production has rate limits that a
misconfigured `dnsZones` selector will burn through in an afternoon, and the
lockout lasts a week.

For machine-to-machine services that do not need public trust, there is an
`internal-ca` ClusterIssuer backed by a cert-manager private CA — cheaper, no
rate limits, and it is how mTLS gets bootstrapped if a mesh ever arrives.

## Open items

- **Replace the `.sops.yaml` placeholder recipients** before the first encrypt.
- **Set the KMS key ID** in `cluster/vault/values.yaml`.
- Once Vault is live, the only secrets left in GitHub should be the age key and
  the GitHub App key. Audit that this is true.
