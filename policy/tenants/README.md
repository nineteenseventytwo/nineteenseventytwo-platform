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
