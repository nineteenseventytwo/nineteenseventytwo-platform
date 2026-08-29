# gha-runner

`ghcr.io/nineteenseventytwo/gha-runner`

Upstream `actions/actions-runner` plus the docker CLI, git, make, and the
`vault` CLI. Nothing else — it should track upstream closely and change
rarely.

`vault` is here for `bootstrap/ssh/sign-ci.sh`, one static binary pinned to
the deployed Vault server's own version — same class of addition as `jq`,
not a reason to reconsider keeping Ansible out (see below).

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

Publishing is tied to bumping `version.txt` — no manual trigger.
`image-gha-runner-build.yml` builds and pushes `:latest` (most recently
built, any branch) from a branch; `image-gha-runner-promote.yml` moves
`:stable` onto that same digest on `main` without rebuilding. See
[ansible-runner's README](../ansible-runner/README.md#versioning) for the
full two-workflow rationale, identical here.

Unlike `ansible-runner`, though, **the runner stack does not consume
`:stable`.** `runner_host_image_tag` pins the explicit version — read
straight from this `version.txt` — because these are long-lived containers,
and an unattended runner should not change underneath a job just because a
tag moved. `ansible-runner` can float to `:stable` precisely because it is
the opposite: a fresh short-lived container per invocation.

## Rolling out a new version

Publishing the image and *running* it are two separate acts, and the gap
between them is real. `make deploy-cicd` carries `require-workstation` —
it restarts the very runner stack a CI job would be executing on, so no
workflow can perform this step. It is a deliberate human action:

1. Bump `version.txt`, open a PR. `image-gha-runner-build.yml` builds,
   signs (cosign, keyless), scans and smoke-tests it from the branch.
2. Merge. `image-gha-runner-promote.yml` retags the tested digest.
3. **`make deploy-cicd` from a workstation.** Until this runs, console is
   still running the previous image — the promote step publishes a tag, it
   does not touch the host.

Between 2 and 3, `main` contains workflows that may expect capabilities the
deployed runner does not have yet. That window is why adding a tool to this
image and making a workflow depend on it are best split across two merges:
ship and roll out the image first, then the workflow that needs it. Doing
both at once is what broke `deploy-nodes` on the `vault` CLI addition — the
image was correct and promoted, the runner was simply still the old one.

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
