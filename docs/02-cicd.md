# 02 — CI/CD

Step 4 of [README's "Rebuild from nothing"](../README.md#rebuild-from-nothing):
`make deploy-cicd`. Stands up org-scoped, ephemeral GitHub Actions runners on
`1972-console-1` and the two images CI runs from. Everything after this phase
— node convergence, the cluster build — runs through these runners instead of
a laptop.

## Prerequisites

- Steps 0–3 done: `make deps` passes, all four Pis imaged, `make test-network`
  passed, all four converged once via `make deploy-nodes` from a workstation
  — [00-bootstrap.md](00-bootstrap.md)
- `nineteenseventytwo` GitHub org exists and this repo lives in it
  ([ADR-0001](decisions/ADR-0001-github-org.md))
- `.sops.yaml` has real recipients (not the placeholders it ships with), and
  `ansible/inventory/lab/group_vars/all/secrets.sops.yml` decrypts with your
  age key — [04-secrets.md § Tier 0](04-secrets.md#1-tier-0--sops--age)

## 1. Create the GitHub App

Replaces repo registration tokens, which expire in an hour and are why the
old setup needed two of them hand-pasted. With an App, the runner container
mints its own registration token at start — no token is ever stored.

1. Org **Settings → Developer settings → GitHub Apps → New GitHub App**,
   owned by `nineteenseventytwo`.
2. Permissions → Organization permissions → **Administration: Read & write**.
   This alone grants `Self-hosted runners: read & write`; nothing else is
   needed.
3. Webhook: leave inactive.
4. Generate a private key (downloads a `.pem`), then **install the App on the
   org**.
5. Record three values: the **Client ID** (App's general settings page), the
   **Installation ID** (URL after installing —
   `.../organizations/nineteenseventytwo/settings/installations/<id>`), and
   the `.pem` contents.

## 2. Store the App credentials

```bash
sops ansible/inventory/lab/group_vars/all/secrets.sops.yml
```

Fill in `github_app_client_id`, `github_app_installation_id`,
`github_app_private_key` with the three values from step 1. Leave
`github_app_id` (the numeric App ID) untouched — it's reserved for ARC's
secret contract in Phase C and unused until then. Save and `sops` re-encrypts
the file on write.

## 3. Set the org Actions secret

**Settings → Secrets and variables → Actions → New organization secret**:

| Secret | Value |
|---|---|
| `SOPS_AGE_KEY` | Private key of the **CI** recipient in `.sops.yaml` (the second one — your own stays on your workstation) |

`KUBECONFIG` is also an org secret, but it belongs to Phase C
(`deploy-cluster.yml`) — nothing in this phase needs it.

## 4. Publish the images

Step 5's `make deploy-cicd` pulls `gha-runner` at the exact tag
`images/gha-runner/version.txt` names — that tag has to already exist in
GHCR first. Push a branch that bumps `images/gha-runner/version.txt` (and
`images/ansible-runner/version.txt`, if it also needs a fresh publish) and
let `image-<name>-build.yml` build, scan, smoke-test and push `:<version>`.
It triggers on any branch but `main`, so this doesn't require merging first.

## 5. Stand up the runner host

```bash
make deploy-cicd
```

Refuses to run from CI (`require-workstation`) — this target restarts
`dockerd` and the runner stack on `1972-console-1` itself, so a runner on
that host running it would kill the job partway through. Run it from your
workstation.

Also generates the `ansible-console` SSH key on `1972-console-1` (never
leaves the host) and authorises it on all four Pis —
[04-secrets.md](04-secrets.md).

## 6. Verify

- Org **Settings → Actions → Runners** lists entries labelled
  `self-hosted, linux, arm64, lab-network`.
- Trigger `deploy-nodes` via **Actions → deploy-nodes → Run workflow** with
  `check_mode: true` (or push a no-op change under `ansible/**` to `main`)
  and confirm the job picks up a self-hosted runner instead of queueing
  forever.

## Definition of done

Two independent triggers, not one — image publishing and node convergence no
longer share a push:

- Bumping an `images/*/version.txt` on a branch builds, scans and
  smoke-tests that image; merging promotes `:stable` by re-tag, not rebuild
  (`image-<name>-build.yml` / `image-<name>-promote.yml`).
- Pushing to `main` under `ansible/**` runs `deploy-nodes.yml`, which pulls
  `ansible-runner:stable` — the last promoted image, not necessarily
  whatever that commit's own `version.txt` says — and converges all four
  Pis. Same default the Makefile uses on a workstation; override
  `ANSIBLE_RUNNER` on either to test a specific version or `:latest`.
- No SSH from your laptop, either way.

---

## Reference

### Where things run

| Job | Runs on | Why |
|---|---|---|
| Lint, test, build arm64 images, push to GHCR | GitHub-hosted `ubuntu-24.04-arm` | Native arm64, no QEMU, no load on the Pi |
| Ansible against Pis, `kubectl apply`, anything touching `192.168.20.x` | Self-hosted, `lab-network` label | LAN reachability — the only reason a self-hosted runner exists here, not compute |

Hosted arm64 runners are available on private repos and count against normal
minutes (private repos get 2 vCPU, public 4).

### Runners hold no state

- Runners run `--ephemeral`: one job, then the container exits and is
  replaced. All repo state comes from `actions/checkout` in the job.
- State lives in three places only: git (config), the registry (artefacts),
  the secrets store (credentials).
- A compromised job can't leave anything behind for the next one to find.

Caching survives this via a registry-backed build cache, not a persistent
runner:

```yaml
cache-from: type=registry,ref=ghcr.io/nineteenseventytwo/ansible-runner:buildcache
cache-to:   type=registry,ref=ghcr.io/nineteenseventytwo/ansible-runner:buildcache,mode=max
```

### Two images, not one

| Image | Contents | Why separate |
|---|---|---|
| [`ansible-runner`](../images/ansible-runner/) | `ansible-core`, pinned collections, `kubectl`, `helm`, `sops`, `age` | Reused outside CI too — console, laptop. Versioned independently of anything GitHub does. |
| [`gha-runner`](../images/gha-runner/) | Upstream runner + docker CLI + git + make | Tracks upstream, changes rarely. Baking Ansible in would mean a collection bump forces a runner rebuild and a runner CVE forces an Ansible revalidation. Carries `make` because workflows drive the platform through `make <target>`. |

The workflow composes them through the Makefile, same as a workstation run:

```yaml
- name: Converge the nodes
  env:
    ANSIBLE_RUNNER: ghcr.io/nineteenseventytwo/ansible-runner:stable
    SSH_KEY: /home/mchellmer/.ssh/ansible-console
  run: make deploy-nodes
```

`:stable` matches the Makefile's own default on a workstation — same tag
either way, unless you override `ANSIBLE_RUNNER` explicitly to test a
version bump or `:latest` on a branch. `SSH_KEY` overrides the Makefile's
workstation default to point at `ansible-console`, which never enters
GitHub.

A step ahead of this one runs `bootstrap/ssh/sign-ci.sh`, which signs a fresh
5-minute certificate over that same keypair using a Vault AppRole credential
that also never enters GitHub — see
[`cluster/vault/README.md`](../cluster/vault/README.md)'s AppRole step for
why AppRole and not Kubernetes auth (the short version: this runs on
`1972-console-1`, which [ADR-0007](decisions/ADR-0007-console-outside-cluster.md)
keeps deliberately outside the cluster, so there's no ServiceAccount token
for Kubernetes auth to validate). The Makefile mounts the resulting cert
automatically once it exists alongside the key — the step above is
unchanged either way; it has no idea whether cert auth is in play.

### Publishing: build once, promote by re-tag

Neither image workflow has a manual trigger — publishing is tied to bumping
`version.txt`, nothing else:

- **`image-<name>-build.yml`**, any branch but `main`: builds, pushes
  `:<version>`, `:sha-<short>`, `:latest` (= "most recently built", not "safe
  to deploy"), scans, smoke-tests. Refuses to push if `:<version>` already
  belongs to a different commit — usually a forgotten version bump.
- **`image-<name>-promote.yml`**, on `main`: no build. Moves `:stable` onto
  the digest the branch build already published (`docker buildx imagetools
  create` — a re-tag, so merging can never produce different bytes than what
  was tested on the branch).

Both are thin callers into `_build-image.yml` / `_promote-image.yml`,
parameterised by image name. `deploy-nodes.yml` / `deploy-cluster.yml` pin to
the exact `:<version>`, never `:stable` — `:stable` is for a future consumer
that wants "whatever's currently blessed."

### The scheduled scan the build workflows can't cover

`_build-image.yml`'s own Trivy step only ever looks at the two images this
repo builds itself, and only once, at build time. Every third-party chart's
image — Cilium, cert-manager, Longhorn, Vault, the whole
kube-prometheus-stack, Argo CD, MetalLB, External Secrets,
kubelet-csr-approver, Prowler — was never scanned for vulnerabilities by
anything in this pipeline, at any point, and a CVE disclosed the day after a
build doesn't get caught by a scan that only runs once.

`image-vuln-scan.yml` closes that on a weekly schedule, against whatever the
cluster is genuinely running rather than a hand-maintained list:

1. **Enumerate** (self-hosted, `lab-network` — the only step that needs a
   path into VLAN 20): lists every unique image reference across every
   running Pod, using `ci-image-inventory`
   ([`policy/41-ci-image-inventory.yaml`](../policy/41-ci-image-inventory.yaml)) —
   a ClusterRole scoped to exactly `pods: get, list`, nothing else. Not
   `trivy k8s`: that mode needs a meaningfully broader ClusterRole by
   default (create/delete Jobs, create Namespaces, for its node-collector
   sub-scan) to produce node-level misconfiguration findings this workflow
   doesn't want — that's Kubescape's job, not this one's.
2. **Scan** (hosted, one per image via a matrix): `trivy image` against each
   reference directly from its own public registry — the same network path
   `_build-image.yml`'s own image scan already assumes, no lab access
   needed. `HIGH,CRITICAL` severity, `--ignore-unfixed` (a CVE with no
   available patch yet isn't actionable, and would be pure noise repeated
   weekly).
3. **Report**: every image's SARIF goes to the Security tab, and a one-line
   count goes to Slack — the Security tab is the actual detail view; Slack
   is "something changed, go look", not a second place to read CVE
   descriptions.

### Two topologies

**Interim — compose on `1972-console-1`.** Before the cluster exists.
`ansible/roles/runner_host` renders the stack; `make deploy-cicd` applies it.
Org-scoped, so "a runner for whichever repo is queueing" is a non-problem —
the entire point of the org ([ADR-0001](decisions/ADR-0001-github-org.md)).
Two replicas, 640 MB memory limit each — on a 2 GB host that's what turns
"console fell over" into "one job failed."

**Target — ARC in-cluster**, once the cluster exists (Phase C):
`gha-runner-scale-set`, org-scoped, GitHub App auth, `minRunners: 0`, defined
by capability rather than repo:

| Scale set | Labels | Use |
|---|---|---|
| `lab-deploy` | `self-hosted, lab-network` | Ansible + kubectl. No privileged container. |
| `lab-dind` | `self-hosted, dind` | Jobs that must build locally. Privileged; scaled to zero. |

The compose stack stays afterwards as the **break-glass path** — it's how you
rebuild the cluster that hosts the other runners.

### The docker socket

Compose runners mount `/var/run/docker.sock` to start sibling containers.
**Socket mount ≈ root on the host.** Mitigated by a dedicated unprivileged
runner user, and by moving to ARC's `dind` mode once the cluster exists.
[ADR-0006](decisions/ADR-0006-runner-docker-socket.md).
