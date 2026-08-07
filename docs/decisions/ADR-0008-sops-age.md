# ADR-0008: SOPS + age; retire ansible-vault

**Status:** Accepted
**Date:** 2026-08-07

## Context

Tier 0 of the secrets model — the config secrets that have to exist before
Vault, before the cluster, before anything. The current setup uses
`ansible-vault` with a shared password, bootstrapped by
`scripts/ansible-vault-init.sh`.

## Decision

SOPS with age recipients. `ansible-vault` and its init script are retired.

## Consequences

- **Encrypts values, not files.** A `git diff` on an encrypted file shows which
  key changed, so a playbook change can be reviewed without decrypting it.
  `ansible-vault` encrypts the whole file into an opaque blob, which means
  review is either "decrypt everything" or "approve blind".
- **Multiple recipients with no shared secret.** Your workstation key and a CI
  key both decrypt; neither is a password that has been pasted into three
  places. Adding or removing a recipient is a re-encrypt, not a rotation event
  across every consumer.
- **One tool across layers.** SOPS works on Kubernetes manifests and Helm values
  as well as Ansible vars, so the GitOps layer uses the same thing.
  `ansible-vault` only ever helps Ansible.
- Age keys are small and easy to rotate.
- **Cost:** `sops` and `age` become hard dependencies of every playbook run,
  which is why they are baked into the `ansible-runner` image. Without them,
  playbooks fail on an undefined variable rather than a clear decryption error.
- The `community.sops` vars plugin must be enabled in `ansible.cfg`; forgetting
  that produces the same confusing undefined-variable failure.
- The age private key is now the root of trust for all of Tier 0. Its blast
  radius is documented in [04-secrets.md](../04-secrets.md) — it is total.

## Alternatives considered

**Keep `ansible-vault`.** Rejected: opaque diffs and a shared password are both
real problems, and neither improves with scale.

**Vault for everything, including Tier 0.** Rejected: circular. Vault runs in
the cluster that Tier 0 secrets are needed to build.
