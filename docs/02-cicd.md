# 02 — CI/CD

## Where things run

This split matters more than anything else here, because `1972-console` has
**1 GB of RAM**.

| Job | Runs on | Why |
|---|---|---|
| Lint, test, build arm64 images, push to GHCR | GitHub-hosted `ubuntu-24.04-arm` | Native arm64, no QEMU, no load on the Pi |
| Ansible against Pis, `kubectl apply`, anything touching `192.168.20.x` | Self-hosted | LAN reachability, and nothing else |

**Self-hosted runners exist because of network position, not compute.** That
framing keeps the Pi out of the build path entirely, and it is the reason the
`lab-network` label exists — it names the actual capability rather than the
machine.

Hosted arm64 runners are available in private repos and count against normal
minutes (private repos get 2 vCPU, public 4).

## Runners hold no state

The instinct to make a runner container hold per-repo state is what forces
hardcoded repo URLs and hand-pasted tokens. The standard model is the opposite:

- Runners are cattle and run `--ephemeral`. One job, then the container exits
  and is replaced. All repo state comes from `actions/checkout` in the job.
- **State lives in three places only**: git (config), the registry (artefacts),
  the secrets store (credentials). Nothing durable in a runner.
- Ephemeral also closes a real hole — a compromised job cannot leave anything
  behind for the next job to find.

The cost is caching. Fix it with a registry-backed build cache, not a
persistent runner:

```yaml
cache-from: type=registry,ref=ghcr.io/nineteenseventytwo/ansible-runner:buildcache
cache-to:   type=registry,ref=ghcr.io/nineteenseventytwo/ansible-runner:buildcache,mode=max
```

## Two images, not one

| Image | Contents | Why separate |
|---|---|---|
| [`ansible-runner`](../images/ansible-runner/) | `ansible-core`, pinned collections, `kubectl`, `helm`, `sops`, `age` | The artefact with real reuse value — run from CI, from console, from a laptop. Versioned independently of anything GitHub does. |
| [`gha-runner`](../images/gha-runner/) | Upstream runner + docker CLI + git | Tracks upstream, changes rarely. Baking Ansible in means a collection bump forces a runner rebuild and a runner CVE forces an Ansible revalidation. |

The workflow composes them:

```yaml
- run: |
    docker run --rm -v $PWD:/work -w /work \
      -v $RUNNER_TEMP/ssh:/root/.ssh:ro \
      ghcr.io/nineteenseventytwo/ansible-runner:1.0.0 \
      ansible-playbook -i ansible/inventory/lab ansible/playbooks/20-cicd-host.yml
```

…which is the same `workflow → make → containerised Ansible → Pis` shape as
before, with the image published rather than built locally.

## Registration: no tokens, ever again

Repo registration tokens expire in an hour, which is why the old script took
two of them as arguments and why it needed a human at both ends.

Replace with a **GitHub App owned by the org**:

1. Create the App under the `nineteenseventytwo` org.
2. Permissions: organisation `Administration: read & write` → grants
   `Self-hosted runners: read & write`.
3. Install it on the org. Store `APP_ID` and the private key **once**.
4. The runner container mints its own registration token at start.

Setup checklist:

```bash
# Org secrets (Settings -> Secrets -> Actions), used by the workflows:
#   SOPS_AGE_KEY          age private key that decrypts group_vars
#   ANSIBLE_SSH_KEY       private half of the runner's node access key
#   ANSIBLE_KNOWN_HOSTS   pinned host keys — host_key_checking is ON
#   KUBECONFIG            scoped kubeconfig for the deploy-cluster job

# Ansible-side (SOPS-encrypted, not a GitHub secret):
#   github_app_id, github_app_installation_id, github_app_private_key
sops ansible/inventory/lab/group_vars/all/secrets.sops.yml
```

## Two topologies

### Interim — compose on `1972-console`

Before the cluster exists. `ansible/roles/runner_host` renders a compose stack;
`make deploy-cicd` applies it. Org-scoped, so "a runner for whichever repo is
queueing" is a non-problem — that is the entire point of the org
([ADR-0001](decisions/ADR-0001-github-org.md)).

Two replicas, 320 MB memory limit each. On a 1 GB host that limit is what turns
"console fell over" into "one job failed".

### Target — ARC in-cluster

`gha-runner-scale-set`, org-scoped, GitHub App auth, `minRunners: 0`. Scale sets
are defined by **capability**, not by repo:

| Scale set | Labels | Use |
|---|---|---|
| `lab-deploy` | `self-hosted, lab-network` | Ansible + kubectl. No privileged container. |
| `lab-dind` | `self-hosted, dind` | Jobs that must build locally. Privileged; scaled to zero. |

Keep the compose stack on `1972-console` afterwards as the **break-glass path** —
it is how you rebuild the cluster that hosts the other runners.

## The docker socket

The compose runners mount `/var/run/docker.sock` so they can start sibling
containers. Be honest about it: **socket mount ≈ root on the host.** The
mitigations are a dedicated unprivileged runner user, and moving to ARC's `dind`
mode once the cluster exists. Recorded in
[ADR-0006](decisions/ADR-0006-runner-docker-socket.md).

## Definition of done for this phase

Push to `main` → GitHub-hosted arm runner builds and pushes `ansible-runner` →
self-hosted runner pulls it → `10-bootstrap-nodes.yml` runs → all four Pis
converge to the hardened baseline. **No SSH from your laptop involved.**
