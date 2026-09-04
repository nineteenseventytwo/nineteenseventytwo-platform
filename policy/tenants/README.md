# Adding a tenant

A "tenant" here is a namespace pair (`<name>-dev`, `<name>-prod`) with its
guardrails: PSS labels, ResourceQuota, LimitRange, default-deny NetworkPolicy.
This directory owns the guardrails only. The workloads that run inside them
live in [`apps/<name>/`](../../apps/) — see [ADR-0012](../../docs/decisions/ADR-0012-platform-owns-app-workloads.md)
for why both moved into this repo.

## Steps

1. Copy [`eightbitsaxlounge.yaml`](eightbitsaxlounge.yaml), rename every
   occurrence, and size the quota to what the app actually needs. Open a PR.
2. Once merged and synced (`make argocd-sync` to skip the poll wait), add the
   workload manifests under `apps/<name>/dev/` and `apps/<name>/prod/` — see
   [`apps/README.md`](../../apps/README.md). The namespace has to exist first,
   which is why this is step 2 and not step 1.
3. Verify the quota actually bites before calling it done:

```bash
kubectl get resourcequota -n <name>-dev
kubectl describe resourcequota tenant-quota -n <name>-dev
```

4. Verify the default-deny boundary holds — a Pod in one tenant namespace
   should not reach a Pod in another:

```bash
kubectl run -n <name>-dev probe --rm -it --image=nicolaka/netshoot -- \
  curl -m3 http://<other-tenant-service>.<other-tenant>-dev.svc.cluster.local
# expect a timeout
```

## Why namespace creation lives here and not in the workload

It is the only way the quota is enforceable rather than advisory. If a
workload manifest under `apps/` could also declare its own namespace, quota
sizing would live wherever the last person to touch it put it, and a namespace
could exist with no quota at all until someone noticed. Splitting "guardrail"
(here) from "what runs inside it" (`apps/`) keeps the constraint somewhere it
cannot be quietly bypassed, while still applying both from the same repo,
reconciled by the same Argo CD instance.

---

# Findings

## The verb set vs what the scripts actually do

`eightbitsaxlounge.yaml`'s `tenant-ci` Role carried a note for months saying
its verbs were "a reasonable baseline, not a transcript of the actual app-repo
scripts… revisit when that migration resumes and the real scripts can be
checked against it." They were checked on 2026-09-04, ahead of the WP-5
migration rather than during it, because Kubescape flagged one of the verbs.

The scripts are not the `eightbitsaxlounge/server` shell the note assumed.
They are four Ansible playbooks: `chat/chat-set-environment.yaml`,
`midi/midi-data-init.yaml`, `midi/midi-data-upload.yaml`,
`midi/midi-request-seteffect.yaml`. Reading them turned up three things, in
all three possible directions — a verb granted and unused, a verb needed and
missing, and a verb needed and deliberately still withheld.

### pods/exec was granted and is used by none of the four

Every task in all four playbooks is `kubectl scale` / `wait` / `get pods` /
`get svc` / `logs`, or an `ansible.builtin.uri` HTTP call against the midi
Service. Not one `kubectl exec`, and no `k8s_exec` module. The grant was made
on a guess about what CI would need and was never exercised.

This was the whole of this cluster's tenant exposure under Kubescape
**C-0002, "Prevent containers from allowing command execution"** — the other
four hits are `kubeadm:cluster-admins`, Argo CD's own application-controller,
Longhorn's support-bundle SA and ARC's runner SA, none of which are ours to
change. Dropped.

### services read was missing, and all three midi playbooks need it

Each opens by resolving the midi Service by label and reading its
`clusterIP`, before doing anything over HTTP:

```yaml
kubectl get svc -n {{ k8s_namespace }} -l app=eightbitsaxlounge,component=midi \
  -o jsonpath='{.items[0].metadata.name}'
```

The Role granted no `services` verb at all, so the first task of all three
would have failed under this credential. Added as `get`/`list`. This is the
more interesting half of the finding: a scan that only looks for excess
privilege found the missing privilege too, because checking the grant against
the consumer is what surfaces both.

### deployments/scale is needed and is still deliberately not granted

`chat-set-environment.yaml` restarts the chat deployment by scaling it to 0,
waiting for the Pod to delete, and scaling it back up. The Role grants
`deployments: get/list/watch` only, and that stays.

Granting `deployments/scale` would let this credential fight Argo CD's
reconciliation loop, which is exactly what the file's own header says the
Role is shaped to prevent — Argo CD owns the replica count of everything
under `apps/`, and a CI job setting it to 0 is a sync conflict, not an
operation. The script is the thing that should change: deleting the Pod and
letting the Deployment's controller recreate it achieves the same restart
inside the verbs already granted (`pods: delete` is there for this).

Until that rewrite lands with WP-5, `chat-set-environment.yaml` will not run
under this credential. That is the intended answer, not an oversight — the
alternative is widening tenant RBAC to match a script that should not have
been written that way.
