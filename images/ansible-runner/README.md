# ansible-runner

`ghcr.io/nineteenseventytwo/ansible-runner`

Contains `ansible-core`, the pinned collections from
[`requirements.yml`](requirements.yml), `kubectl`, `helm`, `sops` and `age`.

Built on a **GitHub-hosted `ubuntu-24.04-arm`** runner — native arm64, no QEMU,
and no load on a Pi. Self-hosted runners exist for network position, not
compute (§3.3), so nothing about this image is built in the lab.

## Use

Runs as a non-root `ansible` user, not root — `--user` below matches it to
whoever is actually invoking `docker run`, so the container reads your key
with your own UID rather than a baked-in one, and anything it writes back to
`/work` comes out owned by you, not root.

```bash
docker run --rm --user "$(id -u):$(id -g)" \
  -v $PWD:/work -w /work \
  -v ~/.ssh/ansible-workstation:/home/ansible/.ssh/id_ed25519:ro \
  -v ~/.config/sops/age:/home/ansible/.config/sops/age:ro \
  -e ANSIBLE_PRIVATE_KEY_FILE=/home/ansible/.ssh/id_ed25519 \
  -e ANSIBLE_CONFIG=/work/ansible/ansible.cfg \
  ghcr.io/nineteenseventytwo/ansible-runner:1.0.0 \
  ansible-playbook -i ansible/inventory/lab ansible/playbooks/10-bootstrap-nodes.yml
```

The `Makefile` wraps exactly this, so `make deploy-nodes` and the
`deploy-nodes.yml` workflow run the same command. It mounts the one SSH key
needed, not all of `~/.ssh` as the snippet above shows for brevity — that
directory holds `mark-workstation` and every other private key on the
machine, none of which a converge has any business being able to read.

## Versioning

`version.txt` is the image tag, and bumping it is what publishes — there is
no manual trigger, and pushing to a branch without touching `version.txt`
builds nothing. Two workflows, "build once, promote by re-tag":

- **`image-ansible-runner-build.yml`**, on any branch but `main`: builds,
  pushes `:$(cat version.txt)`, `:sha-<short>` and `:latest` — meaning "most
  recently built", not "safe to deploy" — signs the digest (cosign,
  keyless), scans, smoke-tests.
- **`image-ansible-runner-promote.yml`**, on `main`: does no build. It moves
  `:stable` onto the digest the branch build already published, via `docker
  buildx imagetools create` — a re-tag, not a rebuild. Merging never
  produces different bytes than what was already tested on the branch.
  `:stable` is what deploys should pin to.

If `version.txt` is bumped directly on `main` without going through a branch
first, promotion fails: there's nothing to promote yet.
