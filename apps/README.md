# apps/

Application workload manifests — Deployments, Services, Ingresses,
ExternalSecrets, per-app NetworkPolicy allow-pairs. This is the other half of
[ADR-0012](../docs/decisions/ADR-0012-platform-owns-app-workloads.md): app
repos build and push images; **what actually runs in the cluster is defined
here**, and Argo CD reconciles it the same way it reconciles `cluster/`.

App repos keep their own CI for build/test/push. They do not get a cluster
credential, do not run `kubectl apply`, and do not carry their own deployment
manifests — those questions all have one answer now, and it is "this repo".

## Layout

```
apps/
  <name>/
    dev/
      *.yaml        # Deployment, Service, Ingress, ExternalSecret, ...
    prod/
      *.yaml
```

`<name>` and the `dev`/`prod` subdirectory together name the namespace the
manifests deploy into: `apps/eightbitsaxlounge/dev/` → namespace
`eightbitsaxlounge-dev`. That namespace, its ResourceQuota, LimitRange and
default-deny NetworkPolicy must already exist — see
[`policy/tenants/`](../policy/tenants/). The ApplicationSet below deliberately
does **not** create namespaces; a workload landing before its guardrails do is
the failure mode this whole design exists to prevent.

## How it is wired

[`cluster/argocd/applications/100-apps.yaml`](../cluster/argocd/applications/100-apps.yaml)
is an `ApplicationSet` with a git directory generator over `apps/*/*`. Every
directory two levels under `apps/` becomes its own Argo CD Application,
automatically, the moment it is merged to `main` — no new Application YAML to
hand-write per app or per environment. That is the concrete mechanism behind
"add a namespace, add it here": create the directory, add manifests, open a
PR. Nothing else to wire up.

Sync wave `100` — after every platform addon and after `policy/` (wave 95), so
a workload never reconciles before the ingress controller, cert-manager, or
its own quota exist.

## Adding an app

1. If the namespace doesn't exist yet, add it (with quota, limits, default-deny)
   in `policy/tenants/<name>.yaml` — copy
   [`policy/tenants/eightbitsaxlounge.yaml`](../policy/tenants/eightbitsaxlounge.yaml)
   as the template. Merge and let it sync before step 2.
2. Create `apps/<name>/<env>/` and add plain Kubernetes manifests. A minimal
   set:

   ```yaml
   # apps/<name>/dev/deployment.yaml
   apiVersion: apps/v1
   kind: Deployment
   metadata:
     name: <name>
     namespace: <name>-dev
   spec:
     replicas: 1
     selector:
       matchLabels: {app: <name>}
     template:
       metadata:
         labels: {app: <name>}
       spec:
         containers:
           - name: <name>
             image: "ghcr.io/nineteenseventytwo/<name>:1.2.3"   # pinned, bumped by PR
             ports: [{containerPort: 8080}]
             resources:
               requests: {cpu: 50m, memory: 64Mi}
               limits: {memory: 256Mi}          # stay inside the tenant quota
   ```

   ```yaml
   # apps/<name>/dev/service.yaml
   apiVersion: v1
   kind: Service
   metadata:
     name: <name>
     namespace: <name>-dev
   spec:
     selector: {app: <name>}
     ports: [{port: 80, targetPort: 8080}]
   ```

   For a secret sourced from Vault, add an `ExternalSecret` — see
   [`cluster/cert-manager/externalsecret-cloudflare.yaml`](../cluster/cert-manager/externalsecret-cloudflare.yaml)
   for the shape; point `secretStoreRef` at the same `vault`
   `ClusterSecretStore` and a `kv/tenants/<name>/...` path.

3. Open a PR. Once merged, the ApplicationSet picks up the new directory on
   its next generator refresh (a few minutes) and creates the Application.
   `make argocd-sync` forces it sooner.

## Image tags are bumped by PR, not auto-updated

There is no Argo CD Image Updater or registry webhook wired up. When an app
repo cuts a release, bump the `image:` tag here in a PR — the same review step
every other change in this repo goes through. If that becomes too much
manual traffic, Image Updater is a values-only addition to the existing Argo
CD release; it was left out to avoid a controller nobody asked for yet.

## What this does not change

- App repos still own their own Dockerfiles, build pipelines, and
  `CHANGELOG.md`/`version.txt` — the artefact they publish to GHCR.
- `policy/tenants/` still owns the namespace, quota, limits and default-deny
  baseline. This directory only owns what runs inside that baseline.
