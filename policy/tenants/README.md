# Adding a tenant

1. Copy `eightbitsaxlounge.yaml`, rename every occurrence, and adjust the quota
   to what the app actually needs. Open a PR.
2. Once merged and synced, mint the kubeconfig the app repo's pipeline will use:

```bash
NS=eightbitsaxlounge-dev
SA=deployer
SERVER=https://192.168.20.202:6443

# Short-lived by default; kubeadm no longer creates permanent SA token Secrets.
# 8760h = 1 year, which is the rotation cadence recorded in docs/04-secrets.md.
TOKEN=$(kubectl -n "$NS" create token "$SA" --duration=8760h)
CA=$(kubectl config view --raw --minify -o jsonpath='{.clusters[0].cluster.certificate-authority-data}')

cat > "${NS}.kubeconfig" <<YAML
apiVersion: v1
kind: Config
clusters:
  - name: nineteenseventytwo
    cluster: {server: ${SERVER}, certificate-authority-data: ${CA}}
contexts:
  - name: ${NS}
    context: {cluster: nineteenseventytwo, namespace: ${NS}, user: ${SA}}
current-context: ${NS}
users:
  - name: ${SA}
    user: {token: ${TOKEN}}
YAML
```

3. Put it in Vault, not in the app repo's GitHub secrets:

```bash
vault kv put kv/tenants/eightbitsaxlounge dev_kubeconfig=@eightbitsaxlounge-dev.kubeconfig
shred -u eightbitsaxlounge-dev.kubeconfig
```

4. Verify the boundary actually holds before handing it over. A tenant token
   that can list namespaces is a tenant token that can read another tenant's
   Secrets, and you want to find that out here:

```bash
export KUBECONFIG=./eightbitsaxlounge-dev.kubeconfig
kubectl auth can-i create deployments -n eightbitsaxlounge-dev   # yes
kubectl auth can-i get secrets -n eightbitsaxlounge-prod         # no
kubectl auth can-i list namespaces                               # no
kubectl auth can-i edit resourcequota -n eightbitsaxlounge-dev   # no
```

## Why namespace creation lives here

It is the only way the quota and RBAC are enforceable. If the app repo creates
its own namespace, it creates it without a quota, and "please add a quota" is a
request rather than a constraint.
