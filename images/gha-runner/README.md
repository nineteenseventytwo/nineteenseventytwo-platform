# gha-runner

`ghcr.io/nineteenseventytwo/gha-runner`

Upstream `actions/actions-runner` plus the docker CLI, git and make. Nothing
else — it should track upstream closely and change rarely.

`version.txt` is this image's **own** semver, the same as `ansible-runner`'s.
The upstream runner version is pinned separately in the Dockerfile's
`RUNNER_VERSION` arg. They move independently: adding a package here is a
`version.txt` bump with `RUNNER_VERSION` unchanged, and a base image bump is
the reverse. Tying the tag to the upstream version instead would mean either
republishing an existing tag with different contents or bolting a revision
suffix onto it — the tag has to keep meaning exactly one image.

`make` is in here because every workflow drives the platform through
`make <target>`, so CI and a workstation run the same definition of the work
rather than two copies that drift. The Makefile then does `docker run
ansible-runner ...` through the mounted socket.

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
