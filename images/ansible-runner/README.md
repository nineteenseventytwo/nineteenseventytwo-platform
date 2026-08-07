# ansible-runner

`ghcr.io/nineteenseventytwo/ansible-runner`

Contains `ansible-core`, the pinned collections from
[`requirements.yml`](requirements.yml), `kubectl`, `helm`, `sops` and `age`.

Built on a **GitHub-hosted `ubuntu-24.04-arm`** runner — native arm64, no QEMU,
and no load on a Pi. Self-hosted runners exist for network position, not
compute (§3.3), so nothing about this image is built in the lab.

## Use

```bash
docker run --rm \
  -v $PWD:/work -w /work \
  -v ~/.ssh:/root/.ssh:ro \
  -v ~/.config/sops/age:/root/.config/sops/age:ro \
  -e ANSIBLE_CONFIG=/work/ansible/ansible.cfg \
  ghcr.io/nineteenseventytwo/ansible-runner:1.0.0 \
  ansible-playbook -i ansible/inventory/lab ansible/playbooks/10-bootstrap-nodes.yml
```

The `Makefile` wraps exactly this, so `make deploy-nodes` and the
`deploy-nodes.yml` workflow run the same command.

## Versioning

`version.txt` is the image tag. Bump it in the same PR as the change; the
build workflow tags `:$(cat version.txt)`, `:sha-<short>`, and moves `:latest`
only on `main`.
