#!/usr/bin/env bash
# Registers this runner using the org's GitHub App instead of a hand-pasted
# token (docs/02-cicd.md, ADR-0006). Flow: sign a JWT with the App's private
# key -> exchange it for an installation access token -> exchange that for a
# runner registration token -> config.sh -> run.sh. Every credential after the
# private key is short-lived and minted fresh here, not passed in.
set -euo pipefail

: "${APP_CLIENT_ID:?required}"
: "${APP_PRIVATE_KEY_PATH:?required}"
: "${APP_INSTALLATION_ID:?required}"
: "${RUNNER_SCOPE:?required}"
: "${LABELS:?required}"

b64url() { openssl base64 -A | tr '+/' '-_' | tr -d '='; }

mint_jwt() {
  local now header payload signing_input signature
  now=$(date +%s)
  header='{"alg":"RS256","typ":"JWT"}'
  # -60s for clock skew against GitHub's server; 9m exp is comfortably under
  # their 10m ceiling for App JWTs. `iss` is the Client ID, not the numeric App
  # ID — GitHub's own JWT guide now recommends it (non-enumerable, and the App
  # ID path may eventually be deprecated):
  # https://docs.github.com/apps/creating-github-apps/authenticating-with-a-github-app/generating-a-json-web-token-jwt-for-a-github-app
  payload="{\"iat\":$((now - 60)),\"exp\":$((now + 540)),\"iss\":\"${APP_CLIENT_ID}\"}"
  signing_input="$(printf '%s' "$header" | b64url).$(printf '%s' "$payload" | b64url)"
  signature=$(printf '%s' "$signing_input" | openssl dgst -sha256 -sign "$APP_PRIVATE_KEY_PATH" -binary | b64url)
  printf '%s.%s' "$signing_input" "$signature"
}

mint_installation_token() {
  curl -sf -X POST \
    -H "Authorization: Bearer $(mint_jwt)" \
    -H "Accept: application/vnd.github+json" \
    "https://api.github.com/app/installations/${APP_INSTALLATION_ID}/access_tokens" \
    | jq -r .token
}

registration_token_url() {
  if [ "$RUNNER_SCOPE" = "org" ]; then
    : "${ORG_NAME:?required when RUNNER_SCOPE=org}"
    printf 'https://api.github.com/orgs/%s/actions/runners/registration-token' "$ORG_NAME"
  else
    : "${REPO_URL:?required when RUNNER_SCOPE=repo}"
    local path="${REPO_URL#https://github.com/}"
    printf 'https://api.github.com/repos/%s/actions/runners/registration-token' "$path"
  fi
}

mint_registration_token() {
  curl -sf -X POST \
    -H "Authorization: Bearer $(mint_installation_token)" \
    -H "Accept: application/vnd.github+json" \
    "$(registration_token_url)" \
    | jq -r .token
}

runner_url() {
  if [ "$RUNNER_SCOPE" = "org" ]; then
    printf 'https://github.com/%s' "$ORG_NAME"
  else
    printf '%s' "$REPO_URL"
  fi
}

RUNNER_NAME="${RUNNER_NAME:-$(hostname)-$RANDOM}"

CONFIG_ARGS=(
  --url "$(runner_url)"
  --token "$(mint_registration_token)"
  --name "$RUNNER_NAME"
  --labels "$LABELS"
  --work "${RUNNER_WORKDIR:-_work}"
  --unattended
  --replace
)
[ "${EPHEMERAL:-false}" = "true" ] && CONFIG_ARGS+=(--ephemeral)
[ "${DISABLE_AUTO_UPDATE:-false}" = "true" ] && CONFIG_ARGS+=(--disableupdate)

./config.sh "${CONFIG_ARGS[@]}"

# Not `exec`: staying in bash lets a docker-stop SIGTERM be forwarded to
# run.sh's real PID below, so the runner's own shutdown handling (which
# deregisters it) actually gets a chance to run instead of the process just
# dying. --ephemeral already self-deregisters on normal job completion; this
# is for the "stopped mid-job or while idle" case.
./run.sh &
runner_pid=$!
trap 'kill -TERM "$runner_pid" 2>/dev/null' TERM INT
wait "$runner_pid"
