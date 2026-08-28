# 04 — Secrets

Cross-cutting, not a single phase — each tier below is set up at a different
point in [README's "Rebuild from nothing"](../README.md#rebuild-from-nothing)
sequence, noted per step. There is a bootstrapping order here, and getting it
wrong is how people end up with Vault credentials in GitHub secrets
protecting the Vault that holds the credentials.

| Tier | Problem | Tool | Root of trust | Set up during |
|---|---|---|---|---|
| 0 | Config secrets before anything exists | **SOPS + age** | age private key: password manager, a GitHub Actions secret, and `/root/.config/sops/age/keys.txt` on console | Phase A/B |
| 1 | CI → AWS | **GitHub OIDC → IAM role** | Nothing stored. Trust policy pins the org and repo. | Phase C |
| 1 | Cluster pods → AWS | **Cluster OIDC issuer → IAM role** | Nothing stored. Trust policy pins the service account. [06-aws-federation.md](06-aws-federation.md) | Phase C |
| 1b | CI → GitHub (runner registration) | **GitHub App private key** | SOPS-encrypted + org secret | Phase B — [02-cicd.md](02-cicd.md) |
| 2 | Cluster workload secrets | **Vault OSS** + **External Secrets Operator** | Vault, auto-unsealed by AWS KMS over IRSA — no key in the cluster | Phase C/D |
| 3 | SSH access | **Vault SSH secrets engine (CA)** | Vault | Phase D |
| 4 | TLS | **cert-manager** + Let's Encrypt DNS-01 | Cloudflare API token, held in Vault | Phase C/D |

## Prerequisites

- `age-keygen`, `sops` installed (`make deps` checks both)
- A GitHub org exists to hold the `SOPS_AGE_KEY` / `KUBECONFIG` Actions
  secrets — [ADR-0001](decisions/ADR-0001-github-org.md)

## 1. Tier 0 — SOPS + age

`sops` + `age`, not `ansible-vault`
([ADR-0008](decisions/ADR-0008-sops-age.md)) — encrypts **values, not
files**, so `git diff` on an encrypted file still shows which key changed,
supports multiple recipients with no shared password, and is one tool across
both Ansible and the GitOps layer.

```bash
age-keygen -o ~/.config/sops/age/keys.txt      # note the public key
# put both public keys (yours + CI's) in .sops.yaml, then
cp ansible/inventory/lab/group_vars/all/secrets.sops.yml{.example,}
sops --encrypt --in-place ansible/inventory/lab/group_vars/all/secrets.sops.yml
```

`.sops.yaml` ships with placeholder recipients — SOPS refuses to encrypt
against a malformed recipient rather than silently producing a file only one
party can read, so it stays inert until you replace them. This tier has to be
working before [02-cicd.md](02-cicd.md) can proceed.

## 2. Tier 1b — GitHub App key

Covered in [02-cicd.md § 1–2](02-cicd.md#1-create-the-github-app) — create
the App, then `sops` the private key into `secrets.sops.yml`. Not repeated
here.

## 3. Tier 2 — Vault + KMS auto-unseal + ESO

Vault OSS **seals itself on every restart**. On a Pi cluster that reboots,
that means hand-unsealing at 11pm. **AWS KMS auto-unseal** removes the manual
step for pennies a month, and exercises KMS key policy along the way — stated
honestly, this makes an on-prem cluster's secrets depend on a cloud KMS. That
is a real dependency, and it's the right trade because the alternative isn't
"no dependency," it's "a dependency on you being awake."

1. Set the KMS key ID in `cluster/vault/values.yaml`.
2. `make bootstrap-argocd` ([03-cluster.md](03-cluster.md)) installs Vault
   and External Secrets Operator via the normal sync waves — nothing here
   waits on a human.
3. Vault auto-unseals from KMS on its own.
4. Populate Vault from the SOPS values **once**, by hand — commands in
   [`cluster/vault/README.md`](../cluster/vault/README.md).

From here, ESO authenticates to Vault with its ServiceAccount token via
Vault's Kubernetes auth — no static Vault credential stored anywhere, which
is exactly the trap this doc opened with. Pair Vault with **External Secrets
Operator**, not the Vault CSI driver or the Agent injector: an
`ExternalSecret` materialises an ordinary Kubernetes Secret, so app manifests
carry no Vault-specific annotations, and the same manifest can point at AWS
Secrets Manager if a workload ever moves to the cloud.

## 4. Tier 3 — SSH certificates

What Phase A ships are SSH **keys**. A real SSH CA signs short-lived
**certificates**, so nodes trust the CA rather than a list of keys.

1. Enable the SSH secrets engine; configure a CA and an `admin` role
   (`allowed_users`, `ttl: 5m`, `default_extensions: permit-pty`).
2. Set `hardening_ssh_trust_ca: true` and re-run `make deploy-nodes` — this
   drops the CA public key on every Pi and sets `TrustedUserCAKeys` in
   `sshd_config`.
3. `bootstrap/ssh/sign.sh 192.168.20.202` signs your key into a 5-minute
   certificate and connects with it.

This buys no `authorized_keys` to manage or drift, revocation that actually
works, an audit log of who requested access to what and when, and
credentials that expire before you've finished making tea — the on-prem
mirror of what `aws configure sso` gives you. Keep **one** break-glass static
key on `1972-console-1`, offline, for when Vault is the thing that's down.

## 5. Tier 4 — TLS

cert-manager + Let's Encrypt via **DNS-01 through Cloudflare**. DNS-01 is the
important choice: it issues browser-trusted certificates for services with
**no inbound internet path at all**. HTTP-01 would require exposing port 80
from VLAN 20 to the internet — the thing the whole network design avoids.

1. Store a Cloudflare token scoped `Zone:DNS:Edit` on the single zone in
   Vault; ESO projects it into the `cert-manager` namespace.
2. Exercise `letsencrypt-staging` first — production has rate limits that a
   misconfigured `dnsZones` selector burns through in an afternoon, and the
   lockout lasts a week.
3. Switch to the production issuer once staging issues cleanly.

For machine-to-machine services that don't need public trust, there's an
`internal-ca` ClusterIssuer backed by a cert-manager private CA — cheaper, no
rate limits, and how mTLS gets bootstrapped if a mesh ever arrives.

## Verify

- [ ] `.sops.yaml` recipients are real, not placeholders, before the first
      encrypt
- [ ] KMS key ID is set in `cluster/vault/values.yaml`
- [ ] Once Vault is live: the only secrets left in GitHub are the age key and
      the GitHub App key — `KUBECONFIG` should be retired too

## Definition of done

Every credential in [the inventory](#secret-inventory) below has an owner, a
rotation cadence, and a documented blast radius if it leaks. Nothing
sensitive is committed in plaintext, and nothing durable lives in a runner
([02-cicd.md](02-cicd.md#runners-hold-no-state)).

---

## Reference

### Secret inventory

The single most interview-legible artefact in the repo, and it takes twenty
minutes to maintain.

| Secret | Lives | Reaches | Rotation | Blast radius if leaked |
|---|---|---|---|---|
| `age` private key | Password manager; `SOPS_AGE_KEY` org secret; console `/root/.config/sops/age/keys.txt` | Every Tier-0 value in this repo | Annual, or immediately on suspicion | **Total for Tier 0** — GitHub App key, Cloudflare token. No longer AWS credentials: those are federated. Rotate by re-encrypting with a new recipient and revoking the old. |
| GitHub App private key | SOPS + org Actions secret | Org runner registration | Annual | Attacker can register runners into the org and receive jobs. Revoke in App settings; regeneration is instant. |
| `ansible-console` SSH key | `1972-console-1` only — generated there by `20-cicd-host.yml`, never in GitHub or git | Nothing anymore as a static entry — **retired from every node's `authorized_keys` 2026-08-28**. The keypair itself is not deleted and should not be: it's the identity Vault signs a fresh certificate over on every CI run (`bootstrap/ssh/sign-ci.sh`); deleting it would break CI, not "finish" the retirement | Annual, or immediately on suspicion — rotate by generating a new keypair, re-running `20-cicd-host.yml`, and confirming `sign-ci.sh` still signs correctly against the new public half | No longer root-equivalent on its own — a copy of this file alone can no longer authenticate anywhere, since no node trusts it as a static key. Compromise now requires *also* forging or stealing a live Vault-signed certificate over it, which expires in 5 minutes. |
| Vault AppRole `secret_id` (`ci-ssh-signer`) | `1972-console-1` only — `/opt/github-runner/vault-ci/secret-id`, `github-runner:github-runner mode:0444` (world-readable inside a single-tenant container; the directory's own `0751` blocks listing), never in GitHub or git | `ssh-client-signer/sign/admin` — nothing else | Annual, or immediately on suspicion (`vault write -f auth/approle/role/ci-ssh-signer/secret-id`, then destroy the old accessor) | `secret_id_bound_cidrs` is the cluster's pod network (`10.244.0.0/16`), not console specifically — console has no path to Vault that preserves its own IP through the ingress hop, confirmed live. The real boundary is the attached policy: a leaked `secret_id`, even from inside the cluster, can only ever request a 5-minute SSH cert for `mchellmer`, nothing broader. |
| `ansible-workstation` SSH key | Workstations only, alongside `mark-workstation`; never in GitHub or git | Nothing anymore as a static entry — **retired from every node's `authorized_keys` 2026-08-28**. Unlike `ansible-console`, nothing currently signs a certificate over this keypair — see the open follow-up below | Moot until something re-adopts this keypair for cert signing; the file itself can be deleted once that's decided either way | No longer root-equivalent on its own, same as `ansible-console` above. |
| Node host keys (`known_hosts`) | Committed at `ansible/files/known_hosts`, regenerated with `make known-hosts` | — | On node reimage | None — these are public keys. Committed rather than held as an Actions secret so `host_key_checking` stays meaningfully on without a credential to distribute. |
| `KUBECONFIG` | Org Actions secret | `deploy-cluster.yml`'s Argo CD nudge-and-wait | On cluster rebuild | Whatever RBAC the embedded credential carries — scope it, don't hand it cluster-admin. Retire once ESO/in-cluster auth makes a static kubeconfig unnecessary. |
| etcd encryption key | `/etc/kubernetes/enc/` on `1972-master-1`, mode 0600 | Every Secret in the cluster at rest | Manual rekey (rewrites every Secret) | Reads every cluster Secret from an etcd snapshot or a stolen SSD. **Back it up with the etcd snapshot, not instead of it — losing it makes every Secret unreadable.** |
| Vault recovery keys | Password manager, split across two entries | `generate-root`, rekey | On personnel change | Full Vault takeover via root token generation. Not unseal keys — auto-unseal is KMS. |
| AWS KMS keys (`sops`, `vault-unseal`) | AWS only. **No credential in the cluster** — pods assume a role via the cluster OIDC issuer ([06-aws-federation.md](06-aws-federation.md)) | Vault's seal; Argo CD's SOPS decryption | Key never; nothing else to rotate | Vault cannot unseal if the role is revoked. There is no long-lived key to leak — that is the point, and `DenyIAMUsersAndKeys` makes creating one impossible. |
| Cloudflare API token | Vault `kv/platform/cloudflare` | `Zone:DNS:Edit` on one zone | Semi-annual | DNS records for one zone — enough to mis-issue certificates for it. Scope to the single zone, never account-wide. |
| App secrets (env vars, API keys) | Vault `kv/tenants/<name>/*` | One namespace each, via `ExternalSecret` | Per-app | Whatever that app's config holds. No app repo can read another's — see [ADR-0012](decisions/ADR-0012-platform-owns-app-workloads.md); there is no tenant kubeconfig anymore, only this. |
| Grafana admin password | Vault `kv/platform/grafana` | Grafana | Annual | Dashboards and datasource credentials. |
| Break-glass SSH key | Offline, on `1972-console-1` | All nodes | Never (audited) | Root-equivalent. Exists precisely for when Vault is the thing that is down. |

### Why the Vault bootstrap order isn't circular

1. SOPS+age holds the bootstrap secrets. No cluster required.
2. Argo CD installs ESO and Vault. Vault auto-unseals from KMS — nothing
   waits on a human.
3. Vault is populated from the SOPS values, **once**, by hand.
4. Everything else reads from Vault via `ExternalSecret`.
