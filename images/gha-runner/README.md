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

No tokens are pasted anywhere. The container authenticates as the org's GitHub
App (`APP_ID` + private key) and mints its own registration token at start —
repo registration tokens expire in an hour, which is why the old script took
two of them as arguments. See [docs/02-cicd.md](../../docs/02-cicd.md).
