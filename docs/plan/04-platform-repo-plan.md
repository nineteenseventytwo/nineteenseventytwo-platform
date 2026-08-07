# Platform Repo Plan — `nineteenseventytwo-platform`
_Extracting server/IaaS concerns out of `eightbitsaxlounge` into a shared, multi-repo platform layer_
_Drafted: August 2026 · pairs with `03-rebuild-timeline.md` Phases 2–4_

---

## 0. Four decisions to make before writing any code

These change the shape of everything below, so settle them first.

| # | Decision | Recommendation | Why it matters |
|---|---|---|---|
| 0.1 | **Create a GitHub organisation** | Yes — `nineteenseventytwo` org (free), move both repos into it | A self-hosted runner can only be registered to **one** repo, org, or enterprise at a time. Org-level runners can serve every repo in the org; **personal accounts cannot have org-level runners**. This is the root cause of your current "two runners, two tokens, hardcoded repo URL" script. Everything downstream (ARC, runner groups, org secrets, one GitHub App) depends on it. |
| 0.2 | **Repo name** | `nineteenseventytwo-platform` | `-baremetal` undersells it (it also owns cluster addons and CI infra); `-server` collides with the folder name you're retiring and reads like "a server app". |
| 0.3 | **Repo visibility** | **Private** | Self-hosted runners + a public repo is a documented RCE path: a fork PR can execute arbitrary code on a machine sitting inside VLAN 20. See §3.5 — this also applies to `eightbitsaxlounge` *today*. |
| 0.4 | **Service mesh** | Not now. Cilium CNI only | See §4.1 — Istio is not a CNI, and you don't need a mesh yet. |

---

## 1. Repository layout

```
nineteenseventytwo-platform/
├── README.md                      # "how do I rebuild everything from nothing"
├── Makefile                       # single entrypoint; CI calls the same targets you do
├── docs/
│   ├── 00-bootstrap.md            # imaging + first boot
│   ├── 01-network-validation.md   # VLAN 20 test matrix (§2.3)
│   ├── 02-cicd.md                 # runners, images, workflows
│   ├── 03-cluster.md              # kubeadm + addons
│   ├── 04-secrets.md              # secret inventory + rotation
│   └── decisions/                 # ADR-0001-github-org.md, ADR-0002-cni.md, ...
├── bootstrap/                     # pre-Ansible; run by hand, exactly once per node
│   ├── cloud-init/
│   │   ├── user-data.j2           # templated; rendered per host
│   │   └── network-config.j2
│   └── ssh/                       # CA config + signing helpers (§5.4)
├── ansible/
│   ├── ansible.cfg
│   ├── inventory/
│   │   ├── lab/hosts.yml          # VLAN 20 static addresses
│   │   └── lab/group_vars/        # *.sops.yml for anything secret
│   ├── roles/
│   │   ├── common/                # apt, unattended-upgrades, chrony, journald caps
│   │   ├── hardening/             # sshd config, TrustedUserCAKeys, ufw, sysctl
│   │   ├── docker/
│   │   ├── runner_host/           # compose stack for bootstrap runners
│   │   ├── kube_prereqs/          # containerd, cgroups, swap, modules, sysctl
│   │   ├── kube_control_plane/
│   │   └── kube_worker/
│   └── playbooks/
│       ├── site.yml
│       ├── 10-bootstrap-nodes.yml
│       ├── 20-cicd-host.yml
│       └── 30-cluster.yml
├── images/
│   ├── ansible-runner/Dockerfile  # ansible-core + collections + kubectl + helm
│   └── gha-runner/Dockerfile      # thin: upstream runner + docker CLI (optional)
├── cluster/                       # everything after `kubeadm init`
│   ├── cilium/values.yaml
│   ├── metallb/
│   ├── ingress-nginx/
│   ├── cert-manager/
│   ├── longhorn/
│   ├── arc/                       # actions-runner-controller + scale sets
│   ├── vault/
│   ├── external-secrets/
│   └── monitoring/                # kube-prometheus-stack
├── policy/                        # default-deny NetworkPolicies, PSS labels, quotas
├── tests/                         # network + node validation (goss / bash)
└── .github/workflows/
    ├── lint.yml                   # yamllint, ansible-lint, checkov, trivy
    ├── build-images.yml           # runs on GitHub-hosted ubuntu-24.04-arm
    ├── deploy-nodes.yml           # self-hosted; needs LAN reach
    └── deploy-cluster.yml         # self-hosted; needs API server reach
```

**The boundary rule:** this repo owns everything cluster-scoped and every infra namespace. App repos own their own namespaces (`eightbitsaxlounge-dev`, `-prod`) and nothing else. Enforced with RBAC, not convention — see §4.4.

---

## 2. Phase A — Imaging, first boot, and VLAN 20 validation

### 2.1 Imaging: use cloud-init, not the Imager GUI

The RPi Imager's "advanced options" panel writes cloud-init `user-data` to the boot partition. Rather than clicking through it four times, commit a template and render it. The imaging step becomes: flash vanilla Ubuntu 24.04 LTS arm64 → drop your rendered `user-data` and `network-config` onto `/boot/firmware/` → boot.

`user-data.j2` should set:

- `hostname`, and the single admin user with `ssh_authorized_keys` (your workstation key only)
- `ssh_pwauth: false`, `lock_passwd: true` — no password auth from first boot
- `package_update: true`, `packages: [qemu-guest-agent-free list...]` — keep it minimal; Ansible does the rest
- `write_files` for `/etc/ssh/sshd_config.d/10-hardening.conf`

`network-config.j2`: static IPv4 on `eth0` (`.201`–`.204`), gateway `192.168.20.1`, DNS `192.168.20.1`. Static in cloud-init **and** a Kea reservation is belt-and-braces; pick one as authoritative and document it. Recommendation: **Kea reservations are authoritative**, cloud-init uses DHCP. That keeps addressing in one place (OPNsense) and means a reimaged Pi comes up correctly with no local edits.

Two Pi-specific gotchas that bit you last time and will again:

| Item | Action |
|---|---|
| cgroups for kubelet | Append `cgroup_enable=memory cgroup_memory=1` to `/boot/firmware/cmdline.txt` (one line, no wrapping) on the **three cluster nodes**. Not needed on `1972-console`. |
| SSD boot | RPi 4 needs its EEPROM `BOOT_ORDER` set to try USB before SD (`rpi-eeprom-config`). Check this on `1972-console` *before* you retire its SD card, not after. |
| Swap | Confirm `swapon --show` is empty; mask `swap.target` in the `common` role. kubelet refuses to start otherwise. |

### 2.2 SSH key strategy — three keys, not one

| Key | Lives where | Used for |
|---|---|---|
| `mark-workstation` (ed25519) | Windows workstation, in Pageant/agent; **private key never leaves the machine** | VLAN 10 → VLAN 20, interactive |
| `ansible-console` (ed25519) | Generated *on* `1972-console`, never checked in | console → all nodes, non-interactive |
| GitHub App private key | sops-encrypted in repo + GitHub Actions secret | runner registration (§3.4) |

You use PuTTY, so generate with `ssh-keygen -t ed25519` and convert with PuTTYgen, or generate in PuTTYgen directly and export the OpenSSH public key. Either is fine; just make sure the *private* key lands in exactly one place.

> **On "SSH certs":** what you have today are SSH **keys**, not certificates. A real SSH CA (Vault's SSH secrets engine) signs short-lived certificates so nodes trust the CA rather than a list of keys — no `authorized_keys` management, instant revocation, and an audit trail. That's the right end state and it's covered in §5.4, but it can't be Phase A because Vault doesn't exist yet. Phase A ships keys; Phase D swaps in the CA and Ansible just adds `TrustedUserCAKeys` to `sshd_config`.

### 2.3 VLAN 20 validation — do this before installing anything

Run these from a Pi on a VLAN 20 access port (switch ports 5–8, PVID 20). `tests/network-check.sh` should codify them so you can re-run after every firewall change.

| # | Test | Command | Expected |
|---|---|---|---|
| 1 | Correct subnet & gateway | `ip -4 a; ip r` | `192.168.20.x/24`, default via `192.168.20.1` |
| 2 | Gateway reachable | `ping -c3 192.168.20.1` | OK (needs the OPNsense rule protocol set to **any**, not TCP) |
| 3 | DNS via Unbound | `dig +short github.com @192.168.20.1` | resolves |
| 4 | Egress TCP | `curl -sI https://ghcr.io \| head -1` | 200/301 |
| 5 | Path MTU | `ping -M do -s 1472 -c3 1.1.1.1` | no fragmentation needed (IPoE + VLAN 1001 should still give 1500; if this fails you have an MTU problem that will show up later as "some HTTPS sites hang") |
| 6 | ARM package archive | `curl -sI http://ports.ubuntu.com \| head -1` | 200 — **`ports.ubuntu.com`, not `archive.ubuntu.com`**, is the arm64 archive; easy to miss when you write the Squid allowlist |
| 7 | VLAN 20 → VLAN 10 **denied** | `nc -vz 192.168.10.50 22` from a Pi | timeout/refused |
| 8 | VLAN 20 → VLAN 30/40 **denied** | `nc -vz 192.168.30.1 80` | timeout |
| 9 | VLAN 10 → VLAN 20 SSH allowed | `ssh mark@192.168.20.202` from Windows | connects |
| 10 | VLAN 10 → VLAN 20 API server | `nc -vz 192.168.20.202 6443` | open (once cluster exists) |
| 11 | Intra-VLAN 20 | Pi → Pi ping | works — and note the firewall **never sees this traffic**; it's switch-local. Inter-node isolation is a NetworkPolicy problem, not a firewall problem. |

**OPNsense rules this implies:**

- Replace `Allow Trusted to any` with the `Internal_Networks` alias fix you already identified: `Trusted → !Internal_Networks` (internet), plus explicit `Trusted → Lab_Nodes` on 22/6443/443.
- `Lab → !Internal_Networks` (internet only), protocol **any**.
- Reserve `192.168.20.240–250` for MetalLB and keep the Kea DHCP pool clear of it (e.g. pool `.100–.199`, reservations `.201–.204`).
- Unbound host overrides for `console/master-1/worker-1/worker-2.lab.<yourdomain>`.

**Squid forethought:** you don't have to enforce it yet, but write the allowlist now so Phase B doesn't fight it. Minimum set for this repo to work: `ports.ubuntu.com`, `security.ubuntu.com`, `ghcr.io` + `pkg-containers.githubusercontent.com`, `registry-1.docker.io` + `production.cloudflare.docker.com` + `auth.docker.io`, `pkgs.k8s.io`, `pypi.org` + `files.pythonhosted.org`, `github.com` + `objects.githubusercontent.com` + `api.github.com`, `quay.io`, `helm.sh`. When you do enforce it, remember three separate proxy configs are needed: shell env, the Docker **daemon** (`/etc/systemd/system/docker.service.d/proxy.conf`), and containerd.

---

## 3. Phase B — CI/CD: images, runners, and the state question

### 3.1 "Does the container hold state for a repo?" — no, and that's the fix

The instinct to make a container hold per-repo state is what's currently forcing you into hardcoded repo URLs and hand-pasted tokens. The standard model is the opposite:

- **Runners are cattle and should be `--ephemeral`.** One job, then the container exits and is replaced. All repo state comes from the `actions/checkout` in the job itself.
- **State lives in three places only:** git (config), the registry (built artefacts), the secrets store (credentials). Nothing durable in the runner.
- Ephemeral runners also close a real security hole: a compromised job can't leave anything behind for the next job to pick up.

Practical consequence: your caching gets worse (no warm `_work` dir, no Docker layer cache). Fix that with a registry-backed build cache (`docker buildx --cache-to type=registry`), not with persistent runners.

### 3.2 One image or two?

**Two.** Keep them separate:

| Image | Contents | Why separate |
|---|---|---|
| `ghcr.io/…/ansible-runner` | `ansible-core`, your `requirements.yml` collections, `kubectl`, `helm`, `sops`, `age` | This is the artefact with real reuse value. You'll run it from CI, from `1972-console`, and from your laptop. It should be versioned and pinned independently of anything GitHub does. |
| `ghcr.io/…/gha-runner` | Upstream runner + `docker` CLI + `git` | Should track upstream closely and change rarely. Baking Ansible in means a collection bump forces a runner rebuild, and a runner CVE forces an Ansible revalidation. |

The workflow then reads:

```yaml
- run: docker run --rm \
    -v $PWD:/work -w /work \
    -v ${{ runner.temp }}/ssh:/root/.ssh:ro \
    ghcr.io/nineteenseventytwo/ansible-runner:1.4.0 \
    ansible-playbook -i inventory/lab playbooks/20-cicd-host.yml
```

…which is exactly your existing `workflow → make → containerised Ansible → Pis` pattern, just with the image published rather than built locally.

The runner container mounts `/var/run/docker.sock` so it can start sibling containers. Be honest in the ADR that **socket mount ≈ root on the host**; the mitigations are a dedicated unprivileged runner user, and moving to ARC's `dind` mode once the cluster exists.

### 3.3 Where things build vs where things deploy

This split matters more than anything else in this section, because `1972-console` has 1 GB of RAM.

| Job type | Runs on | Rationale |
|---|---|---|
| Lint, test, **build arm64 images**, push to GHCR | **GitHub-hosted `ubuntu-24.04-arm`** | Native arm64, no QEMU emulation, no load on the Pi. These are now available in private repos too (Jan 2026) and count against your normal free minutes; public repos get 4 vCPU, private 2 vCPU. |
| Ansible against Pis, `kubectl apply`, anything needing 192.168.20.x | **Self-hosted** | Only reason to be self-hosted is LAN reachability. |

Framing it as "self-hosted runners exist because of network position, not compute" keeps the Pi out of the build path entirely and is a clean thing to say in an interview.

### 3.4 Runner registration: stop pasting tokens

Repo registration tokens expire in an hour, which is why your current script takes two of them as arguments. Replace with a **GitHub App** owned by the org:

- Permissions: `Administration: read & write` (org) → `Self-hosted runners: read & write`.
- Install it on the org; store `APP_ID` + private key once.
- The runner container (e.g. `myoung34/github-runner`, which accepts `APP_ID`/`APP_PRIVATE_KEY`) mints its own registration token at start. No human in the loop, ever again.

### 3.5 Two runner topologies — interim, then target

**Interim (Weeks 1–3, before the cluster exists):** docker-compose on `1972-console`, one service per repo scope, rendered from a template in this repo.

```yaml
# ansible/roles/runner_host/templates/compose.yml.j2
services:
  runner-org:
    image: ghcr.io/nineteenseventytwo/gha-runner:2.x
    environment:
      ORG_NAME: nineteenseventytwo      # org-scoped: serves every repo
      APP_ID: "${APP_ID}"
      APP_PRIVATE_KEY: "${APP_PRIVATE_KEY}"
      EPHEMERAL: "true"
      LABELS: self-hosted,linux,arm64,lab-network
    volumes: [/var/run/docker.sock:/var/run/docker.sock]
    restart: always
    deploy: {replicas: 2}
```

Because it's org-scoped, "a runner for whichever repo is queueing" becomes a non-problem — that's the whole point of decision 0.1.

**Target (once the cluster is stable):** **Actions Runner Controller** (`gha-runner-scale-set`, GA at 0.14.0 as of March 2026) in-cluster, org-scoped, GitHub App auth, `minRunners: 0`. Define scale sets by *capability*, not by repo:

| Scale set | Labels | Use |
|---|---|---|
| `lab-deploy` | `self-hosted, lab-network` | Ansible + kubectl |
| `lab-dind` | `self-hosted, dind` | jobs that must build locally |

Keep the compose runner on `1972-console` as the break-glass path — it's how you rebuild the cluster that hosts the other runners.

**Security note you should act on this week:** `eightbitsaxlounge` is public and has self-hosted runners attached. A fork PR is a code-execution path onto a machine in your lab VLAN. Either set Actions → "Require approval for all external contributors", or route `pull_request` jobs to GitHub-hosted runners only, or make the repo private. Write this up as a decision record — it's a good threat-model artefact.

### 3.6 Definition of done for Phase B

Push to `main` on `nineteenseventytwo-platform` → GitHub-hosted arm runner builds and pushes `ansible-runner` → self-hosted runner pulls it → runs `10-bootstrap-nodes.yml` → all four Pis converge to the hardened baseline. No SSH from your laptop involved.

---

## 4. Phase C — Kubernetes

### 4.1 On Istio: it isn't a CNI, and you don't need it yet

Worth being precise, because the two layers get conflated constantly:

| Layer | Job | Options |
|---|---|---|
| **CNI** | Pod IPs, routing, L3/L4 NetworkPolicy | Cilium, Flannel, Calico. Istio is **not** in this list. |
| **Service mesh** | Workload identity, mTLS, L7 policy, canary routing | Istio, Linkerd, Cilium Service Mesh |

Istio *ships* a component called the "Istio CNI node agent", but that only handles traffic redirection — it still needs a real CNI underneath. Cilium and Istio are complementary, not alternatives.

**Recommendation: Cilium only, defer the mesh.** Reasons:

1. Your control plane and workers are RPi 5s with **2 GB RAM** already running Longhorn and kube-prometheus-stack. Istio sidecar mode is off the table. Ambient mode is lighter and has supported arm64 since Istio 1.15, but `istiod` + `ztunnel` on 2 GB nodes is a real squeeze.
2. Cilium already gives you the things you actually want next: NetworkPolicy enforcement (which Flannel couldn't do), Hubble flow observability, and **transparent node-to-node encryption via WireGuard** — encryption in transit without a mesh.
3. A mesh has a clear trigger. Adopt one when you need **L7 policy, per-workload mTLS identity, or traffic-shifting**. Not before.

If/when that trigger fires, Istio **ambient** on top of Cilium is the right choice (Linkerd's stable-build situation makes it harder to recommend now). Note the documented prerequisite: with default-deny CiliumNetworkPolicies in place, ambient breaks kubelet health probes unless you explicitly allow the SNAT-ed probe source `169.254.7.127/32`. Record that in the ADR so future-you doesn't lose an evening.

### 4.2 Build order

```
containerd + kube_prereqs (all 3 nodes)
  → kubeadm init on 1972-master-1   [etcd encryption at rest, PSS admission config]
  → Cilium                          [helm; kube-proxy replacement optional]
  → join worker-1, worker-2
  → default-deny NetworkPolicy in every namespace
  → MetalLB (L2, 192.168.20.240–250)
  → ingress-nginx
  → cert-manager (DNS-01 / Cloudflare)
  → Longhorn (worker SSDs, 2 replicas)
  → kube-prometheus-stack
  → Kubescape CIS scan  ← baseline artefact, cluster still empty
  → ARC
```

Everything after `kubeadm init` is a Helm release with a values file in `cluster/`, applied by the pipeline. No `kubectl apply` from your laptop; that's the discipline that makes it reproducible.

`1972-console` (RPi 4, 1 GB) **stays out of the cluster**. It's the bootstrap node that builds the cluster; putting it in creates a circular dependency and 1 GB won't take a kubelet plus a runner.

### 4.3 kube-proxy replacement — optional, one gotcha

Cilium's kube-proxy replacement is a nice thing to have done, but it requires `k8sServiceHost`/`k8sServicePort` in the Helm values (the API server can't be reached via a Service that doesn't exist yet). If the cluster build is already fighting you, ship standard mode first and flip it later — it's a supported migration.

### 4.4 The shared-cluster boundary

This is the actual reason you're splitting the repo, so make it explicit rather than implicit:

| Owned by `platform` | Owned by app repos |
|---|---|
| CNI, MetalLB, ingress controller, cert-manager, Longhorn, monitoring, ARC, Vault | Their own namespaces and everything in them |
| Cluster-scoped RBAC, PSS namespace labels, default-deny policies | Their own Deployments, Services, Ingresses, NetworkPolicy allow-pairs |
| **Per-tenant ServiceAccount + namespaced Role + ResourceQuota + LimitRange** | Consuming the kubeconfig they're handed |

Concretely: `platform` creates `eightbitsaxlounge-dev` and `-prod`, plus a ServiceAccount per environment with a Role scoped to that namespace, then publishes the resulting kubeconfig into the secrets store. The app repo's pipeline reads it and can't touch anything else. ResourceQuota matters more than it sounds on 2 GB nodes — one runaway Deployment shouldn't be able to evict Prometheus.

Namespace *creation* moving to `platform` is a small change from your current plan (you suggested leaving it in the app repo), but it's what makes the quota and RBAC enforceable.

---

## 5. Phase D — Secrets and certificates

There's a bootstrapping order here, and getting it wrong is how people end up with Vault credentials in GitHub secrets protecting the Vault that holds the credentials.

### 5.1 The layers

| Tier | Problem | Tool | Where the root of trust lives |
|---|---|---|---|
| 0 | Config secrets before anything exists | **SOPS + age** | age private key: your password manager, a GitHub Actions secret, and `/root/.config/sops/age/keys.txt` on console |
| 1 | CI → AWS | **GitHub OIDC → IAM role** | Nothing stored. Trust policy pins the org/repo. |
| 1b | CI → GitHub (runner registration) | **GitHub App private key** | sops-encrypted + org secret |
| 2 | Cluster workload secrets | **Vault OSS** + **External Secrets Operator** | Vault, auto-unsealed by AWS KMS |
| 3 | SSH access | **Vault SSH secrets engine (CA)** | Vault |
| 4 | TLS | **cert-manager** + Let's Encrypt DNS-01 | Cloudflare API token, held in Vault |

### 5.2 Tier 0: SOPS + age, and retire ansible-vault

Your timeline doc left this as "ansible-vault **or** sops+age". Pick sops+age:

- Encrypts **values, not files** — `git diff` stays readable, so you can review a change to a playbook without decrypting.
- Multiple recipients (your key + a CI key) without a shared password.
- Works on Kubernetes manifests and Helm values too, so it's the same tool for the GitOps layer later. ansible-vault only ever helps Ansible.
- `age` keys are tiny and easy to rotate compared to a shared vault password that's been pasted into three places.

### 5.3 Tier 2: Vault, and the unseal problem nobody mentions

Vault OSS **seals itself on every restart** and needs unseal keys to come back. On a Pi cluster that reboots, that means you're hand-unsealing at 11pm. Use **AWS KMS auto-unseal** — costs pennies per month, removes the manual step, and has the side benefit of exercising KMS key policy, which is squarely on your target-role syllabus.

Pair Vault with **External Secrets Operator** rather than the Vault CSI driver or Agent injector. ESO's `ExternalSecret` CRD materialises a normal Kubernetes Secret, so app manifests don't need Vault-specific annotations, and you can point the same manifest at AWS Secrets Manager when a workload moves to the cloud. That backend-swap property is exactly the "Vault vs managed" comparison you wanted to be able to talk about.

### 5.4 Tier 3: SSH certificates — the direct answer to "certs for VLAN 10 → VLAN 20"

Once Vault is up:

1. Enable the SSH secrets engine, configure a CA and a role (`allowed_users`, `ttl: 5m`, `default_extensions: permit-pty`).
2. Ansible drops the CA public key on every Pi and sets `TrustedUserCAKeys /etc/ssh/ca.pub` in `sshd_config`.
3. You run `vault ssh -mode=ca -role=admin mark@192.168.20.202`; Vault signs your key into a 5-minute certificate.

What this buys: no `authorized_keys` files to manage or drift, revocation that actually works, an audit log of who requested access to what and when, and credentials that expire before you've finished making tea. It's the on-prem mirror of the short-lived-credential pattern you're already planning with `aws configure sso`.

Keep one break-glass static key on `1972-console`, offline, for when Vault is the thing that's down.

### 5.5 Tier 4: TLS

`cert-manager` + Let's Encrypt via **DNS-01 through Cloudflare**. DNS-01 is the important choice: it issues browser-trusted certs for services that have **no inbound internet path at all**, which is exactly your situation. Cloudflare API token scoped to `Zone:DNS:Edit` on the single zone, stored in Vault and projected by ESO into the `cert-manager` namespace.

For machine-to-machine internal services that don't need public trust, add a `ClusterIssuer` backed by a cert-manager private CA. Cheaper, no rate limits, and it's how you'd bootstrap mTLS later.

### 5.6 Keep a secret inventory

One table in `docs/04-secrets.md`: every secret, where it lives, what it can reach, rotation cadence, and blast radius if leaked. It takes twenty minutes and it's the single most interview-legible artefact in this whole repo.

---

## 6. Migration from `eightbitsaxlounge/server`

Cut over in this order; don't delete anything until the replacement rebuilds a node end to end.

| Current | Destination | Notes |
|---|---|---|
| `scripts/init.sh` | `ansible/roles/common` | Drops installing Ansible on the host entirely — container-first |
| `scripts/github-runner.sh` | `ansible/roles/runner_host` + compose template | Replaced by org-scoped, App-authenticated, ephemeral containers |
| `init-nodes.yaml`, `init-console.yaml` | `playbooks/10-bootstrap-nodes.yml` | Console no longer needs to be a DHCP server — Kea on OPNsense does that now |
| `init-kubernetes.yaml`, `k8s-*.yaml` | `cluster/` Helm values + `playbooks/30-cluster.yml` | Flannel manifest is dropped; Cilium replaces it |
| `init-pc.yaml` | `playbooks/` (keep) | The Windows/PowerShell SSH setup is still needed for `midi-api`; note the PC is on a tagged trunk (VLAN 10 Windows / VLAN 20 Linux) |
| `k8s-namespaces.yaml` | Split | Namespace + quota + RBAC → `platform`; workloads stay in the app repo |
| `scripts/ansible-vault-init.sh` | Retired | Replaced by sops+age |
| `server/README.md` | Replaced by `docs/` | Leave a stub pointing at the new repo |

---

## 7. Suggested sequencing (fits `03-rebuild-timeline.md` Phases 2–3)

| Week | Work | Done when |
|---|---|---|
| 1 | Create org, move repos, create `platform` repo, GitHub App, ADRs 0001–0004 | Org-level runner page exists |
| 2 | Cloud-init templates, image all 4 SSDs, run the §2.3 test matrix | All four Pis reachable from VLAN 10 by key; VLAN 20 → VLAN 10 provably blocked |
| 3 | `common`/`hardening`/`docker` roles, `ansible-runner` image, `build-images.yml` on hosted arm runner | Image in GHCR, built without touching a Pi |
| 4 | Compose runner stack on console, `deploy-nodes.yml` | Push to main reconfigures a Pi with no human SSH |
| 5–6 | kubeadm + Cilium + join workers + default-deny + Kubescape baseline | Empty hardened cluster; before/after scan committed |
| 7 | MetalLB, ingress-nginx, cert-manager, Longhorn | First HTTPS ingress with a real Let's Encrypt cert |
| 8 | Vault + KMS auto-unseal + ESO; migrate sops secrets in | Nothing sensitive left in GitHub secrets except the age key and App key |
| 9 | ARC scale sets; SSH CA cutover; tenant namespaces + RBAC for eightbitsaxlounge | App repo deploys to its own namespace with a scoped token |

---

## 8. Open questions

1. Are you willing to make `eightbitsaxlounge` private, or do you want the public showcase value? If public, the fork-PR mitigation in §3.5 needs deciding this week, not later.
2. `1972-console` — confirm the RPi 4's EEPROM boot order supports USB SSD before you retire the SD card.
3. Do you want GitOps (Argo CD / Flux) reconciling `cluster/`, or is pipeline-driven `helm upgrade` enough? Pipeline-driven is simpler and fine at this size; Argo is a better interview story. Either way the directory layout above supports both.
4. Does the PC's Linux side join the cluster in this phase or later? It's the only x86 node and the only GPU, so it changes scheduling and image architecture assumptions (multi-arch builds become mandatory the day it joins).
5. Is AWS available for KMS auto-unseal by the time Vault lands? If not, plan a manual-unseal interim and don't let it become permanent.
