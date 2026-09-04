# Rebuild — the master sequence

**The one ordered document.** Everything in `docs/00`–`07` is a *reference* for
one part of this sequence; this page is the sequence itself, and it is the only
page that says what order things happen in.

Read it top to bottom during a build. Do not drive a build from the component
docs — build 0001 did, and the result was a Kubescape baseline that was never
captured because no single document ever said when to capture it
([build 0001](builds/0001-initial-build.md#what-this-build-changed-about-the-runbook)).

> **Open a build log before step 0.1.** Copy
> [`builds/TEMPLATE.md`](builds/TEMPLATE.md) to `builds/NNNN-<name>.md` and fill
> in the deviations table *as you go*. The runbook below is corrected from those
> logs; a build that does not write one leaves the next build to rediscover the
> same things.

## Phase map

| Phase | What | Reference | Gate |
|---|---|---|---|
| **0** | Pre-flight — nothing is touched yet | [04](04-secrets.md), [06](06-aws-federation.md) | `make deps`, JWKS bucket exists, versions pinned, **SSH trust reset (0.7)** |
| **A** | Nodes: image, network, converge | [00](00-bootstrap.md), [01](01-network-validation.md) | `make test-network`, `make deploy-nodes CHECK=1` idempotent |
| **B** | CI/CD host and runners | [02](02-cicd.md) | A job runs on a self-hosted runner |
| **C** | Kubernetes cluster | [03](03-cluster.md), [06](06-aws-federation.md) | Nodes `Ready`, **baseline scan captured** |
| **D** | Argo CD, Vault, and everything in `cluster/` | [03](03-cluster.md), [04](04-secrets.md) | All Applications `Synced/Healthy` |
| **E** | Identity: SSH CA cutover | [04](04-secrets.md#4-tier-3--ssh-certificates) | Legacy keys retired |
| **F** | Close out | this page | Evidence captured, build log closed |

Each step below has a **gate**. A gate is not a suggestion — every one of them
exists because build 0001 moved past that point without checking and paid for it
later. If a gate fails, fix it before the next step; do not carry it.

---

## Phase 0 — Pre-flight

Nothing here touches the hardware, and all of it is cheaper to get wrong now
than in Phase C.

### 0.1 Open the build log

```bash
cp docs/builds/TEMPLATE.md docs/builds/0002-<name>.md
```

Add a row to [`builds/README.md`](builds/README.md). Copy the previous build's
`Carried into` items into this one's `Carried in`.

### 0.2 Workstation tooling

```bash
make deps                     # podman/docker, sops, age
RUNNER_LOCAL=1 make deps      # also ansible, kubectl, helm
```

**Gate:** clean exit.

### 0.3 Tier 0 secrets — SOPS + age

Reference: [04-secrets.md § 1](04-secrets.md#1-tier-0--sops--age).

`.sops.yaml` has real recipients (yours + CI's + the KMS recipient), and
`ansible/inventory/lab/group_vars/all/secrets.sops.yml` decrypts with your age
key.

```bash
sops -d ansible/inventory/lab/group_vars/all/secrets.sops.yml >/dev/null
```

**Gate:** decrypts without prompting. Everything in Phase A and B reads from
this file; a build that discovers a missing recipient at `deploy-cicd` has
already imaged four SSDs.

### 0.4 The AWS side must exist first — **one-way door ahead**

Reference: [06-aws-federation.md steps 0–1](06-aws-federation.md).

The JWKS bucket must exist in `nineteenseventytwo-cloud`
(`create_jwks_bucket = true`) **before** Phase C, because `kubeadm init` fixes
the API server's `--service-account-issuer` permanently. Building the cluster
with the wrong issuer means pods can never federate to AWS and the only fix is
rebuilding the control plane.

**Gate:** the bucket exists, and `cluster_oidc_issuer` in
`ansible/inventory/lab/group_vars/all/vars.yml` matches the issuer the published
discovery document will carry, character for character.

### 0.5 Pin the versions this build is testing

Record the target versions in the build log's header. Then confirm every pin
still resolves — a chart pinned months ago may have been yanked, and
`lint-helm` catches a bad values key, not a missing version:

```bash
helm repo update
helm search repo <repo>/<chart> --versions | head    # per chart in cluster/*/values.yaml
make lint-helm
```

**Gate:** `make lint-helm` renders every chart. Build 0001 swept six chart pins
in a single sitting (#83–#89) because nothing checked them until they were
already deployed.

### 0.6 Network: OPNsense before anything boots

Reference: [00-bootstrap.md § 1](00-bootstrap.md#1-reservations-first) and
[01-network-validation.md](01-network-validation.md).

- Kea reservations for all four MACs (`.201`–`.204`)
- DHCP pool `.100–.199`, MetalLB `.240–.250`, **no overlap**
- VLAN 20 rules, protocol **any** — not TCP
- Unbound host overrides: the four nodes, plus `argocd.`, `vault.`, `grafana.`
  pointing at the pinned Gateway address in
  [`cluster/gateway/00-gateway.yaml`](../cluster/gateway/00-gateway.yaml)

**Gate:** none yet — it is proved at 1.2, which is why 1.2 comes before any
install.

### 0.7 Reset the SSH trust state — **a from-scratch build is locked out without this**

`main` carries the *end state* of the previous build, not the starting state of
this one. Two defaults in
[`ansible/roles/hardening/defaults/main.yml`](../ansible/roles/hardening/defaults/main.yml)
are the problem:

```yaml
hardening_ssh_trust_ca: true              # trust bootstrap/ssh/ca.pub
hardening_ssh_retire_legacy_keys: true    # reconcile authorized_keys to exactly
hardening_ssh_authorized_keys: []         # ... this list, which is empty
```

On a from-scratch rebuild, step **1.3** (`make deploy-nodes`) therefore empties
`authorized_keys` on `1972-master-1`, `1972-worker-1` and `1972-worker-2` —
removing the workstation keys cloud-init just installed — and points
`TrustedUserCAKeys` at `bootstrap/ssh/ca.pub`, which is the **previous** Vault's
CA public key. A rebuilt Vault runs `generate_signing_key=true` and produces a
*new* keypair, so the private half that could sign a usable certificate no
longer exists anywhere.

The three cluster nodes become unreachable, and it fails *late*: the run that
does it succeeds, because its own SSH connection is already established. The
next run — and every step of Phase B and C — cannot connect. Only
`1972-console-1` survives, via `break-glass.pub`.

**Before step 1.3**, set both flags to their Phase A state:

```yaml
hardening_ssh_trust_ca: false
hardening_ssh_retire_legacy_keys: false
```

and treat the CA cutover as [Phase E](#phase-e--identity), exactly as build 0001
did it — after the new Vault exists and `bootstrap/ssh/ca.pub` has been replaced
with the new CA's public key.

**Gate:** both flags are `false`, and you have confirmed `make deploy-nodes` does
not appear in any workflow that would run before you have re-read this.

> Each flag's own comment block describes the Phase A state correctly. What is
> missing is anything that ties the two together at rebuild time — which is what
> this step is. See [build 0001](builds/0001-initial-build.md#carried-into-build-0002).

---

## Phase A — Nodes

### 1.1 Image each host

Reference: [00-bootstrap.md](00-bootstrap.md).

```bash
make bootstrap-render HOST=1972-console-1     # repeat per host
```

Flash vanilla Ubuntu 24.04 arm64, copy `build/<host>/{user-data,network-config}`
onto the boot partition, boot. Do **not** use the Imager's advanced-options
panel.

**Gate:** all four hosts reachable — `make ping`.

### 1.2 Prove the network — before installing anything

```bash
make test-network              # tests 1-8, 11, 12 on a Pi
```

Then from the workstation, tests 9 and 10 (they report *skipped* on a Pi):

```bash
ssh mchellmer@192.168.20.202
nc -vz 192.168.20.202 6443     # after the cluster exists
```

**Gate:** exit code 0. **Do not skip test 12** (Unbound overrides for
`argocd.`/`vault.`/`grafana.`) — build 0001 worked around it with `curl
--resolve` and `/etc/hosts` for months, and only found it when CI's own
certificate signing needed a resolvable name and had none.

### 1.3 Converge every node

```bash
make deploy-nodes              # CHECK=1 for a dry run first
```

Run from the workstation this first time; the runner that would otherwise run it
does not exist yet.

### 1.4 Assert the baseline

```bash
make deploy-nodes CHECK=1
```

Re-runs the exact playbook 1.3 just applied, in check mode — an idempotency
check on precisely what Phase A converged. **Gate:** zero `changed` across all
four hosts. Anything reported as would-change here is real drift 1.3 left
behind, not a false negative — unlike 1.3's own `docker-ce` check-mode
artifact, this run has nothing left to write, so there is no "would exist
after a repo add" ambiguity to explain away a `changed`.

**Not `make test-nodes`.** That target runs `site.yml --check --diff` —
Ansible's own "everything, in dependency order" comment on that file is
accurate, and it means all three phases: nodes, CI/CD host, and cluster. Run
here, mid-build, before Phase B and C exist, it fails on tasks that assume
`deploy-cicd`/`deploy-cluster` already ran (confirmed live: `Could not find the
requested service github-runner: host` — the CI/CD play's own systemd check,
querying a service `deploy-cicd` hasn't created yet). `test-nodes` is the
right check for a **fully built** cluster asserting reality still matches git,
not a Phase-A-only gate — that distinction wasn't in this doc until it was
tried mid-build here.

Goss ([`tests/goss/node.yaml`](../tests/goss/node.yaml)) is a separate,
stronger assertion of the same baseline, but neither target above runs it — it
needs the `goss` binary on each node and is invoked there by hand. See
[`tests/README.md`](../tests/README.md#gossnodeyaml) if you want that
additional check; `memory-cgroups-enabled` failing there on `1972-console-1`
is correct — it is not a cluster node.

---

## Phase B — CI/CD

Reference: [02-cicd.md](02-cicd.md).

### 2.1 GitHub App and org secrets

- Create the org-owned GitHub App, Organization → **Administration: Read & write**
- `sops` the client ID, installation ID and private key into `secrets.sops.yml`
- Org Actions secret `SOPS_AGE_KEY` = the CI recipient's private key

### 2.2 Stand up the runner stack

```bash
make deploy-cicd
```

**Gate:** the runners register **and a job actually runs on one**. Registered is
not the same as working — see
[07-runbooks.md](07-runbooks.md#self-hosted-runner-containers-crash-loop-after-a-host-reboot)
for the failure where GitHub shows a healthy runner and jobs queue forever.

---

## Phase C — Kubernetes

Reference: [03-cluster.md](03-cluster.md), [06-aws-federation.md](06-aws-federation.md).

### 3.1 One-way door — confirm the issuer before you run anything

Re-read 0.4. `kube_control_plane` asserts the issuer is set and well formed and
refuses if a running control plane disagrees with the inventory, but understand
what it is protecting before you proceed.

### 3.2 Build the cluster

```bash
make deploy-cluster            # CHECK=1 for a dry run
```

kubeadm init on `1972-master-1` (etcd encryption at rest, PSS admission, audit
policy) → Cilium via Helm → join both workers → default-deny NetworkPolicy.
Run from the workstation.

### 3.3 Kubeconfig

```bash
make kubeconfig                # writes ./build/kubeconfig
```

Store it as the org secret `KUBECONFIG`. Scope it — do not hand out
cluster-admin if you can avoid it.

### 3.4 Publish the OIDC discovery documents

Reference: [06-aws-federation.md steps 3–5](06-aws-federation.md).

```bash
make publish-oidc
```

Then deploy the Cloudflare Worker so the public URL resolves. `publish-oidc`
verifies the public URL and fails until the Worker is up — that failure is
expected on a first run, not a defect.

**Gate:** `kubectl get nodes` — control plane and both workers `Ready`.

### 3.5 ★ Capture the pre-install baseline ★

**This is the step build 0001 missed, and it is why this runbook exists.**

The window is open exactly once per build: after the cluster is hardened, and
*before* Argo CD brings up ~50 workloads that make the scan a measurement of the
workloads rather than of the cluster.

```bash
kubescape scan framework nsa --format json \
  --output docs/builds/0002-baseline-nsa.json
```

**Gate:** the file exists and is committed. Nothing in Phase D starts until it
is. Record the compliance score in the build log — build 0001's post-install
number was 72/100 with 93 High findings, and a pre-install number is not
comparable to it, which is exactly the point.

---

## Phase D — Argo CD and the platform

### 4.1 Hand the cluster to Argo CD

```bash
make bootstrap-argocd
```

The last `helm install` a human ever runs. After this, changing the cluster is a
PR against [`cluster/`](../cluster/).

**Immediately after, restart `cilium-operator`:**

```bash
kubectl -n kube-system rollout restart deployment/cilium-operator
```

Cilium is installed pre-Argo by `30-cluster.yml`, before the Gateway API CRDs
exist — those land later, as part of this step. `cilium-operator`'s own
Gateway API watches never retry establishing themselves once the CRDs appear
after it has already started; without this restart, the `gateway` resource
sits `PROGRAMMED: Unknown` indefinitely and nothing that signs an SSH
certificate over the public hostname (Phase E) can reach it. Found in build
0002, recurred in build 0003 because it had only ever been logged as a
carried-forward TODO rather than added here — see
[build 0003's log](builds/0003-ssh-cutover-retry.md) for the second time this
cost real time.

### 4.2 Wait for the first sync

```bash
make argocd-sync-wait
```

Expect this to be where a rebuild finds things. The sync waves are in
[`cluster/README.md`](../cluster/README.md); a wave that will not go healthy
blocks every wave after it.

### 4.3 Vault: initialise, unseal, populate

Reference: [04-secrets.md § 3](04-secrets.md#3-tier-2--vault--kms-auto-unseal--eso)
and [`cluster/vault/README.md`](../cluster/vault/README.md).

Vault auto-unseals from AWS KMS over IRSA, so there is no 11pm hand-unseal — but
that only works if 0.4 and 3.4 are both correct.

### 4.4 Prove federation end to end

```bash
make verify-irsa
```

**Gate:** an assumed-role identity comes back. Vault reporting
`Seal Type: awskms` and unsealed is the same proof by another route — that state
is unreachable unless the SA token → STS → KMS chain works.

### 4.5 Prove the policy, do not claim it

```bash
make verify-default-deny
```

**Gate:** exit code 0. Build 0001 spent eleven `fix/` PRs on NetworkPolicy gaps
found by deploying rather than by checking; this target is the check.

### 4.6 Post-install scan — the other half of the pair

```bash
kubescape scan framework nsa --format json \
  --output docs/builds/0002-postinstall-nsa.json
```

The before/after pair across the Cilium and default-deny work is worth more than
either scan alone.

**Gate:** the failing controls match
[ADR-0017](decisions/ADR-0017-kubescape-accepted-controls.md)'s table. Not the
score — the score is expected to drop post-install and saying so proves
nothing. Diff the set:

```bash
jq -r '.summaryDetails.controls | to_entries | map(.value)
       | map(select(.status=="failed")) | sort_by(.controlID)
       | .[] | "\(.controlID) \(.name) \(.ResourceCounters.failedResources)"' \
  docs/builds/0003-postinstall-nsa.json
```

Anything in that output and not in ADR-0017 is a new finding and is triaged
before the build closes. Build 0003 logged this step as "expected, not a bug"
and moved on; going through the controls one at a time afterwards found three
real issues and proved the highest-weighted control was measuring the wrong
layer.

---

## Phase E — Identity

Reference: [04-secrets.md § 4](04-secrets.md#4-tier-3--ssh-certificates),
[`bootstrap/ssh/README.md`](../bootstrap/ssh/README.md), build 0001's
#47/#52, and [build 0002's failure](builds/0002-k8s1.67.md#carried-into-build-0003)
— read that before starting this phase, not after.

> **`deploy-nodes` (CI) only ever sees what is pushed to `main`.** It runs
> against a fresh checkout of the branch on a self-hosted runner, not your
> local disk — a commit that has not been pushed is invisible to it, and so
> is an edit that was never committed at all. This is exactly how build 0002
> lost SSH to every cluster node: `hardening_ssh_retire_legacy_keys: false`
> and the new `ca.pub` were both fixed and confirmed correct *locally*, but
> `deploy-nodes` kept running against the old committed `true`/old-CA state
> — which reconciled `authorized_keys` to empty on every node but console
> (a one-way ratchet) while trusting a CA the new Vault can no longer sign
> against. By the time the real fix was pushed, the very `deploy-nodes` run
> needed to deliver it had no SSH access left to run with. Recovery required
> pulling SD cards on three of four hosts.
>
> **Before triggering `deploy-nodes` at any step in this phase** — by hand or
> by merging a PR that runs it automatically — confirm:
>
> ```bash
> git status --short ansible/roles/hardening/defaults/main.yml bootstrap/ssh/ca.pub
> git log origin/main..HEAD -- ansible/roles/hardening/defaults/main.yml bootstrap/ssh/ca.pub
> ```
>
> Both must be empty. If either prints anything, push first.

This phase undoes step 0.7 deliberately, in the order that works:

1. **Generate the new CA** in the new Vault and export its public half:

   ```bash
   vault secrets enable -path=ssh-client-signer ssh
   vault write ssh-client-signer/config/ca generate_signing_key=true
   vault read -field=public_key ssh-client-signer/config/ca > bootstrap/ssh/ca.pub
   ```

   Commit **and push** the new `ca.pub` — see the warning above — before any
   `deploy-nodes` run touches it. The one in git before this point belongs to
   the previous cluster and signs nothing.

2. **Confirm `vault.eightbitsaxlounge.com` resolves from `1972-console-1`** —
   `tests/network-check.sh 12`. Nothing enforces this earlier and it fails
   silently until CI tries to sign.

3. **Trust the CA, keep the static keys:** `hardening_ssh_trust_ca: true`,
   `hardening_ssh_retire_legacy_keys` still `false`. **Push this before**
   re-running `make deploy-nodes` — the flags gate is only real once it is on
   the branch CI reads. Both routes in now work.

4. **Prove signing works both ways** before removing the fallback — `make ssh-ws
   HOST=192.168.20.202` for the human path, and `bootstrap/ssh/sign-ci.sh` via
   the AppRole for CI's.

5. **Confirm `bootstrap/ssh/break-glass.pub` is present and correct** — `cat` it,
   do not trust a comment. Console's `authorized_keys` is emptied too if it is
   missing.

6. **Only then cut over:** flip `hardening_ssh_retire_legacy_keys: true` in its
   own PR and re-run. This is the step that is irreversible in practice — its
   own defaults comment explains why flipping back does not restore anything.

**Gate:** `make ssh-ws HOST=192.168.20.202` works, and static-key SSH to a
cluster node is refused.

## Phase F — Close out

### Evidence

- [ ] `docs/builds/NNNN-baseline-nsa.json` — pre-install (3.5)
- [ ] `docs/builds/NNNN-postinstall-nsa.json` — post-install (4.6)
- [ ] `make test-network` — 12/12
- [ ] `make test-nodes` — all four hosts
- [ ] `make verify-default-deny` — 0
- [ ] `make verify-irsa` — assumed-role identity
- [ ] `kubectl -n argocd get applications` — all `Synced/Healthy`

### Definition of done

The cluster is reachable, Argo CD reconciles `cluster/` from `main`, and every
box above is ticked. From here there is no more `kubectl apply` from a laptop —
that discipline is what makes the cluster reproducible rather than merely
documented.

### Close the build log

Fill in the PR counts and compare the `fix/` share against the previous build.
Move anything still open into the next build's `Carried into` section. Then
correct **this page** from the deviations table — a runbook that survives a
build unchanged either was perfect or was not followed.
