# gha-runner

`ghcr.io/nineteenseventytwo/gha-runner`

Upstream `actions/actions-runner` plus the docker CLI and git. Nothing else —
it should track upstream closely and change rarely.

`version.txt` tracks the **upstream runner version**, not an independent
release number, so a bump here means a bump of the base image.

## Why it holds no state

Runners are cattle and run `--ephemeral`: one job, then the container exits and
is replaced. State lives in three places only — git (config), the registry
(artefacts), the secrets store (credentials). Nothing durable in the runner.

That also closes a real hole: a compromised job cannot leave anything behind
for the next job to pick up.

The cost is caching — no warm `_work` directory, no local layer cache. The fix
is a registry-backed build cache, not a persistent runner:

```yaml
- uses: docker/build-push-action@v6
  with:
    cache-from: type=registry,ref=ghcr.io/nineteenseventytwo/ansible-runner:buildcache
    cache-to: type=registry,ref=ghcr.io/nineteenseventytwo/ansible-runner:buildcache,mode=max
```

## Registration

No tokens are pasted anywhere. `entrypoint.sh` authenticates as the org's
GitHub App: it signs a JWT (`iss` = `APP_CLIENT_ID`, GitHub's recommended claim
over the numeric App ID) with `APP_PRIVATE_KEY_PATH`, exchanges it for an
installation access token (`APP_INSTALLATION_ID`), exchanges that for a runner
registration token, then runs `config.sh`/`run.sh`. Every credential after the
private key is short-lived and minted fresh on each container start — repo
registration tokens expire in an hour, which is why the old script took two of
them as arguments. See [docs/02-cicd.md](../../docs/02-cicd.md).

This is a from-scratch entrypoint against the official
`ghcr.io/actions/actions-runner` base, not the `myoung34/docker-github-actions-runner`
image the original plan named — kept the base thin and upstream-tracking
rather than taking a third-party image's dependency on the App private key.
