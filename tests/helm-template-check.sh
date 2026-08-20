#!/usr/bin/env bash
# Render every pinned chart against its values file.
#
#   tests/helm-template-check.sh          # or: make lint-helm
#
# Each cluster/*/values.yaml carries a `# chart: <version>` comment, and the
# same string appears in that component's Argo Application. Rendering here
# catches a values key the pinned chart version does not have — which
# otherwise surfaces not as an error but as a setting that is silently
# ignored, i.e. the failure mode you find months later.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

command -v helm >/dev/null 2>&1 || {
  echo "error: helm not found on PATH" >&2
  exit 1
}

add() { helm repo add "$1" "$2" >/dev/null; }
add cilium               https://helm.cilium.io/
add metallb              https://metallb.github.io/metallb
add ingress-nginx        https://kubernetes.github.io/ingress-nginx
add jetstack             https://charts.jetstack.io
add longhorn             https://charts.longhorn.io
add external-secrets     https://charts.external-secrets.io
add hashicorp            https://helm.releases.hashicorp.com
add prometheus-community https://prometheus-community.github.io/helm-charts
add argo                 https://argoproj.github.io/argo-helm
helm repo update >/dev/null

fail=0
check() { # chart, values path
  local chart="$1" values="$2" version
  version=$(grep -m1 '^# chart:' "$values" | awk '{print $3}')
  if [[ -z "$version" ]]; then
    echo "--- $chart ($values): no '# chart:' version comment" >&2
    fail=1
    return
  fi
  echo "--- $chart @ $version ($values)"
  helm template test "$chart" --version "$version" -f "$values" >/dev/null || fail=1
}

check cilium/cilium                              cluster/cilium/values.yaml
check metallb/metallb                            cluster/metallb/values.yaml
check ingress-nginx/ingress-nginx                cluster/ingress-nginx/values.yaml
check jetstack/cert-manager                      cluster/cert-manager/values.yaml
check longhorn/longhorn                          cluster/longhorn/values.yaml
check external-secrets/external-secrets          cluster/external-secrets/values.yaml
check hashicorp/vault                            cluster/vault/values.yaml
check prometheus-community/kube-prometheus-stack cluster/monitoring/values.yaml
check argo/argo-cd                               cluster/argocd/values.yaml

exit $fail
