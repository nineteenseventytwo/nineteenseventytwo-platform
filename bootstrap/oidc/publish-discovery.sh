#!/usr/bin/env bash
# Publish the cluster's OIDC discovery documents to the public JWKS bucket.
#
#   bootstrap/oidc/publish-discovery.sh
#   make publish-oidc
#
# This is the step that makes IRSA work. The API server signs projected
# service-account tokens with a private key; AWS STS verifies them against the
# matching public key, which it fetches over the open internet from the issuer
# URL. Nothing here is a secret — a JWKS is public signing keys, the same as
# Google's or GitHub's. The security boundary is the `sub`/`aud` condition on
# each IAM role, not the secrecy of this document.
#
# Run it:
#   - once, after `kubeadm init`, before turning on publish_cluster_oidc
#   - again, immediately, if the service-account signing key is ever rotated.
#     Rotating without republishing invalidates every token in the cluster and
#     the failure is instant and total. This belongs on the rotation checklist
#     next to the SSH CA.
#
# Requires an `aws sso login` session with PlatformAdmin on platform-prod, and
# a kubeconfig with permission to read the two discovery endpoints.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_ROOT"

# Defaults mirror ansible/inventory/lab/group_vars/all/vars.yml, which in turn
# mirrors nineteenseventytwo-cloud/config/aws.json. Overridable so a rebuild
# under a different account or domain does not need an edit here.
ISSUER="${ISSUER:-https://oidc.eightbitsaxlounge.com}"
BUCKET="${BUCKET:-nineteenseventytwo-oidc-972034964468}"
AWS_REGION="${AWS_REGION:-eu-west-2}"

KUBECTL="${KUBECTL:-kubectl}"
export AWS_REGION

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

echo "==> Reading discovery documents from the cluster" >&2
$KUBECTL get --raw /.well-known/openid-configuration > "$TMP/openid-configuration"
$KUBECTL get --raw /openid/v1/jwks                   > "$TMP/jwks"

# The issuer inside the document has to equal the public URL character for
# character. A mismatch — most often a trailing slash, or a cluster built
# before the issuer flag was set — produces an "invalid identity token" from
# STS that says nothing whatsoever about URLs. Fail here, where the message can
# actually say what is wrong.
ACTUAL_ISSUER=$(sed -n 's/.*"issuer"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' \
  "$TMP/openid-configuration" | head -1)

if [[ "$ACTUAL_ISSUER" != "$ISSUER" ]]; then
  cat >&2 <<MSG
error: issuer mismatch.

  cluster says : ${ACTUAL_ISSUER:-<none>}
  expected     : ${ISSUER}

The API server's --service-account-issuer is fixed at kubeadm init and cannot
be changed on a running cluster. If the cluster reports the kubeadm default
(https://kubernetes.default.svc), it was built before the issuer was set and
IRSA cannot work on it — the control plane has to be rebuilt with
cluster_oidc_issuer in place. See docs/06-aws-federation.md.
MSG
  exit 1
fi

echo "==> Issuer matches: ${ISSUER}" >&2

# These two keys are the OIDC protocol, not a convention chosen here. STS
# derives the JWKS location from the discovery document, and the discovery
# document lives at a well-known path by definition.
echo "==> Uploading to s3://${BUCKET}" >&2
aws s3 cp "$TMP/openid-configuration" \
  "s3://${BUCKET}/.well-known/openid-configuration" \
  --content-type application/json
aws s3 cp "$TMP/jwks" \
  "s3://${BUCKET}/openid/v1/jwks" \
  --content-type application/json

echo "==> Verifying the public endpoint" >&2
# Verified from outside, through Cloudflare, because that is the path STS takes.
# A successful S3 upload proves nothing about whether AWS can reach the issuer.
FAILED=0
for path in /.well-known/openid-configuration /openid/v1/jwks; do
  code=$(curl -fsS -o /dev/null -w '%{http_code}' "${ISSUER}${path}" 2>/dev/null) || code=000
  if [[ "$code" == "200" ]]; then
    echo "    200  ${ISSUER}${path}" >&2
  else
    echo "    ${code}  ${ISSUER}${path}" >&2
    FAILED=1
  fi
done

if [[ "$FAILED" == "1" ]]; then
  cat >&2 <<MSG

The documents are in the bucket but the public URL does not serve them yet.
That is expected if Cloudflare is not wired up — deploy the Worker in
bootstrap/oidc/worker.js and add the oidc DNS record first.

Do NOT set publish_cluster_oidc=true until both paths return 200. Registering
an IAM OIDC provider whose issuer does not resolve fails in a way that reads
like a permissions error and sends you looking in the wrong place entirely.
MSG
  exit 1
fi

echo >&2
echo "Both endpoints live. Safe to set publish_cluster_oidc=true in" >&2
echo "nineteenseventytwo-cloud/live/aws/platform-prod and apply." >&2
