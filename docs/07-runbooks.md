# 07 — Runbooks

Incidents worth a documented fix rather than rediscovering them from scratch
next time, and the one planned procedure that avoids them. The two incident
entries after it share the same shape: an unclean host reboot
left stale local state behind, and a plain **restart** of the affected
process reused that state instead of clearing it — only a **recreate** did.
Worth remembering as a pattern, not just two one-off fixes, going into any
future work on scheduled reboots or planned cluster downtime.

## Applying node updates

**When:** `NodeRebootRequired`, `NodeUpdatesPending` or
`NodeSecurityUpdatesPending` fires in Slack. The metrics come from the
`node-apt-metrics` timer (`ansible/roles/common`), which runs hourly, so an
alert clears within an hour of the fix.

`unattended-upgrades` already installs security updates every day and never
reboots. Routine updates and reboots are this procedure. Do it **one node at a
time: workers first, the control plane last.** Longhorn keeps two replicas on
the workers, so a second worker must not go down while the first one's
replicas are still rebuilding.

```bash
export KUBECONFIG=build/kubeconfig
NODE=1972-worker-1 IP=192.168.20.203

# 1. Every Longhorn volume healthy before starting
kubectl -n longhorn-system get volumes.longhorn.io \
  -o custom-columns=NAME:.metadata.name,ROBUSTNESS:.status.robustness

# 2. Move the workloads off
kubectl drain $NODE --ignore-daemonsets --delete-emptydir-data

# 3. Update and reboot. kubelet, kubeadm, kubectl, containerd stay held.
make ssh-ws HOST=$IP
sudo apt-get update && sudo apt-get upgrade -y && sudo reboot

# 4. Back in service, then wait for step 1 to show healthy again before the
#    next node
kubectl wait --for=condition=Ready node/$NODE --timeout=10m
kubectl uncordon $NODE
```

**The control plane (`1972-master-1`) last.** Its reboot is a few minutes of
API outage: Argo CD, kubectl and CI pause, and running workloads carry on.
Afterwards, check the next entry. A control plane that comes back with stale
static pods is the known failure here.

`1972-console-1` and `1972-gpu-1` get the same `unattended-upgrades` and
timer, but no node-exporter scrapes them. Check them by hand while you are at
it: `cat /var/lib/node_exporter/textfile/apt.prom`.

## Control plane static pods stuck after a node reboot

**Symptom:** `kube-controller-manager` and/or `kube-scheduler` on a control
plane node sit in `CreateContainerError` and never recover on their own.
Nothing gets scheduled or reconciled cluster-wide while they're down —
including the Job/CronJob controller, so queued CronJob runs never produce a
Pod. `kubectl get events -A --field-selector type=Warning` shows containerd
refusing to recreate the container: `failed to reserve container name
"...", is reserved for "<old-sandbox-id>"` — a stale name reservation left
over from before the reboot.

**Why `systemctl restart kubelet` alone doesn't fix it:** kubelet's own pod
worker for that static pod is wedged against the same stale containerd
state; restarting kubelet doesn't force it to re-evaluate the manifest and
retry from scratch.

**Fix** — force kubelet to see a fresh delete+create of the static pod by
cycling its manifest out of the watched directory and back in:

```bash
sudo mv /etc/kubernetes/manifests/kube-controller-manager.yaml /tmp/
sudo mv /etc/kubernetes/manifests/kube-scheduler.yaml /tmp/
sleep 5
sudo mv /tmp/kube-controller-manager.yaml /etc/kubernetes/manifests/
sudo mv /tmp/kube-scheduler.yaml /etc/kubernetes/manifests/
```

**Verify:**

```bash
kubectl get pods -n kube-system -l component=kube-controller-manager
kubectl get pods -n kube-system -l component=kube-scheduler
kubectl get componentstatuses          # both report Healthy
kubectl create job -n security probe --from=cronjob/prowler-scan
# ... then delete it; a Pod actually appearing confirms the Job controller
# and scheduler are both live, not just the containers looking up
```

## Self-hosted runner containers crash-loop after a host reboot

**Symptom:** GitHub's UI shows the runner as registered, but queued jobs
matching its label sit `Waiting to be picked up` indefinitely.
`docker ps -a` on `1972-console-1` shows `github-runner-1`/`github-runner-2`
`Restarting (1)`. `docker logs` shows the entrypoint trying to register on
every restart and failing: `System.InvalidOperationException: Cannot
configure the runner because it is already configured.`

**Why this happens:** `cluster/../compose.yml.j2` (via
`ansible/roles/runner_host`) sets `restart: always`, and only the runner's
own **work directory** is a named volume — there is no volume for its
install/config directory. Docker's `restart: always` restarts the *same*
container object, reusing its existing writable layer. If the container
exits uncleanly (a reboot mid-job) rather than through the normal ephemeral
completion path (run one job, deregister, exit 0), the `.runner` config file
from its prior successful registration survives in that layer, and the
entrypoint's unconditional `configure` on the next start collides with it
forever. GitHub's own UI has no way to know this — it only reflects the
runner's last-reported state, not whether the process is actually alive.

**Fix** — remove and recreate the containers (not `docker restart`), which
drops the stale in-container state since nothing outside the workdir volume
persists across it:

```bash
cd /opt/github-runner
sudo docker compose rm -sf runner-1 runner-2
sudo docker compose up -d runner-1 runner-2
```

**Verify:**

```bash
docker ps --filter name=github-runner --format 'table {{.Names}}\t{{.Status}}'
# both "Up ... (healthy)", not Restarting
docker logs github-runner-1 --tail 5   # "Listening for Jobs"
```

Then re-run (or wait out) the queued workflow and confirm it actually starts.
