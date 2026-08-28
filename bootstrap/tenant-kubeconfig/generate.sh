#!/usr/bin/env bash
# Build a kubeconfig for a tenant's CI-scoped ServiceAccount and publish it
# to Vault, where the app repo's pipeline reads it.
#
#   bootstrap/tenant-kubeconfig/generate.sh <tenant> <namespace>
#
# e.g. bootstrap/tenant-kubeconfig/generate.sh eightbitsaxlounge eightbitsaxlounge-dev
#
# Reads the long-lived token Secret <tenant>-ci-token that
# policy/tenants/<tenant>.yaml declares for exactly this purpose (Kubernetes
# 1.24+ no longer auto-creates one), builds a kubeconfig scoped to that one
# namespace, and writes it to kv/tenants/<tenant>/kubeconfig-<env> - <env>
# is the part of the namespace after the tenant name (eightbitsaxlounge-dev
# -> dev), matching how every other tenant secret is addressed.
#
# Requires: kubectl pointed at the cluster (build/kubeconfig), vault CLI +
# VAULT_ADDR + a token with write access to kv/tenants/<tenant>/*.
set -euo pipefail

TENANT="${1:?usage: generate.sh <tenant> <namespace>}"
NAMESPACE="${2:?usage: generate.sh <tenant> <namespace>}"
SA_NAME="${TENANT}-ci"
SECRET_NAME="${SA_NAME}-token"
ENV="${NAMESPACE#"${TENANT}"-}"

if ! command -v kubectl >/dev/null 2>&1; then
  echo "error: kubectl not found" >&2
  exit 1
fi

if ! command -v vault >/dev/null 2>&1; then
  echo "error: vault CLI not found; see docs/04-secrets.md" >&2
  exit 1
fi

if [[ -z "${VAULT_ADDR:-}" ]]; then
  echo "error: VAULT_ADDR is unset (e.g. https://vault.\${LAB_DOMAIN})" >&2
  exit 1
fi

if ! kubectl get secret "$SECRET_NAME" -n "$NAMESPACE" >/dev/null 2>&1; then
  echo "error: secret ${NAMESPACE}/${SECRET_NAME} not found - is policy/tenants/${TENANT}.yaml applied?" >&2
  exit 1
fi

TOKEN="$(kubectl get secret "$SECRET_NAME" -n "$NAMESPACE" -o jsonpath='{.data.token}' | base64 -d)"
CA_CERT="$(kubectl get secret "$SECRET_NAME" -n "$NAMESPACE" -o jsonpath='{.data.ca\.crt}')"
API_SERVER="$(kubectl config view --raw --minify -o jsonpath='{.clusters[0].cluster.server}')"
CLUSTER_NAME="$(kubectl config view --raw --minify -o jsonpath='{.clusters[0].name}')"

TMP_KUBECONFIG="$(mktemp)"
trap 'rm -f "$TMP_KUBECONFIG"' EXIT

cat > "$TMP_KUBECONFIG" <<EOF
apiVersion: v1
kind: Config
clusters:
  - name: ${CLUSTER_NAME}
    cluster:
      server: ${API_SERVER}
      certificate-authority-data: ${CA_CERT}
contexts:
  - name: ${SA_NAME}
    context:
      cluster: ${CLUSTER_NAME}
      namespace: ${NAMESPACE}
      user: ${SA_NAME}
current-context: ${SA_NAME}
users:
  - name: ${SA_NAME}
    user:
      token: ${TOKEN}
EOF

vault kv put "kv/tenants/${TENANT}/kubeconfig-${ENV}" "kubeconfig=@${TMP_KUBECONFIG}"

echo "published to kv/tenants/${TENANT}/kubeconfig-${ENV}"
echo "scoped to namespace ${NAMESPACE} only - verify with:"
echo "  vault kv get -field=kubeconfig kv/tenants/${TENANT}/kubeconfig-${ENV} > /tmp/check.kubeconfig"
echo "  KUBECONFIG=/tmp/check.kubeconfig kubectl auth can-i --list"
