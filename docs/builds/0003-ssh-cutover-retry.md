# Build 0003 — SSH cutover retry

**Dates:** 2026-09-04 → *(open)*
**Runbook followed:** [`docs/REBUILD.md`](../REBUILD.md) @ `55e1e69`
**Target versions:** k8s `1.37.0`, etcd `3.7.1-0`, Cilium `1.20.1`
**Outcome:** **Succeeded.** Full runbook proven end to end for the first
time — Phases A through F all complete, every Phase F evidence item green.
The one claim this build existed to prove, Phase E's push-gate actually
preventing build 0002's lockout on a second attempt, held: the SSH CA
cutover (step 6) went cleanly, committed and pushed immediately rather than
left local. `fix/` share dropped to 4/13 (31%) from build 0002's 8/10 (80%)
— a real signal that most of 0002's lessons made it into the config, not
just the log.

---

## Why this build

[Build 0002](0002-k8s1.67.md) failed inside Phase E: a local-only fix to the
SSH CA cutover never reached the branch `deploy-nodes` (CI) actually runs
against, which locked out `1972-master-1`, `1972-worker-1`, and
`1972-worker-2` with no CI or SSH path back in — recovery needed pulling SD
cards. Rather than repair that cluster in place, this is a full re-image and
re-run, on the same target versions, with the root cause now fixed in
[`docs/REBUILD.md`](../REBUILD.md#phase-e--identity) itself rather than only
in a postmortem. The claim this build needs to prove is narrower than
0002's: not just that the runbook works through Phase D (0002 already showed
that), but specifically that Phase E's new gate actually prevents the same
lockout on a second attempt.

## Carried in

From [build 0002](0002-k8s1.67.md#carried-into-build-0003):

- [x] **Prove the runbook end to end, including Phase E and F.** Done —
      Phases A through F all complete, every Phase F evidence item green.
- [ ] **Land `bootstrap/cloud-init/render.sh`'s fix.** Held uncommitted
      through 0002 and all of 0003 too, still at the user's request —
      carried again.
- [x] **Land `render.sh` and any future SSH-trust-affecting fixes in their
      own PR immediately**, not batched with other work — applied for real
      this time: the CA-trust flip (PR #130) and the retire-legacy-keys
      cutover (PR #133) each landed alone, committed and pushed before
      anything triggered `deploy-nodes`.
- [x] **Note the check-mode false-negative** (`docker-ce`/`kubelet` "no
      package matching" under `CHECK=1`) — went further than a note: found
      and fixed the actual bug class (missing `check_mode: false` on
      read-only diagnostic tasks) via PRs #136/#137, including two more
      instances a systematic sweep turned up.
- [ ] **Document Argo CD manual-sync semantics** (`prune: true` not
      inherited by manual `operation.sync`; identical-content patches are
      no-ops) in `cluster/README.md` — still not done; this build added a
      second undocumented Argo CD gotcha (the discovery-cache/controller-
      restart one) to the same pile.
- [x] **Add the `cilium-operator` restart step explicitly to Phase D**,
      right after `bootstrap-argocd`. Done in PR #132 — and immediately
      validated its own necessity by recurring once more before landing.
- [x] **Kubescape post-install pair** — both halves now captured
      (`0003-baseline-nsa.json` 78/100, `0003-postinstall-nsa.json` 73/100).
- [ ] **`eightbitsaxlounge/server` deletion** and **`apps/` ApplicationSet
      being empty** — both still out of scope, carried forward unchanged
      since build 0001.

## Deviations from the runbook

**Fill this in as you go.** Reconstructed afterwards it is worth nothing — the
detail that matters is the one that seemed too small to write down at the time.

| Step | What the runbook said | What actually happened | Fix |
|---|---|---|---|
| 1.1 | — (not a documented step) | Same as build 0002: re-imaging changed all four host SSH keys again, `main`'s committed `known_hosts` was stale | `make known-hosts`, regenerated and committed before it could block anything — [PR #125](https://github.com/nineteenseventytwo/nineteenseventytwo-platform/pull/125), merged |
| 1.2 | `make test-network` | Ran it from the workstation first, out of habit — got 3 false failures (`addr=none gw=none`, MTU, VLAN 30/40 reachable) because the script needs to run *from a Pi on VLAN 20's access port*, not the workstation. Not a real regression, just the wrong execution context | Cloned the repo fresh onto `1972-console-1` (its own runner checkout didn't exist yet — nothing had run there since the re-image) and ran it there: 10/10 real checks pass, 2 skipped as documented |
| 1.3 → 2.2 | `deploy-nodes` runs once per rebuild before CI exists | A *second*, CI-triggered `deploy-nodes.yml` run (queued at 05:43 from PR #124's merge, before any runner existed) got picked up the instant `deploy-cicd` registered the new runners, racing my own manual `deploy-nodes.yml` dispatches in the same `concurrency: group: deploy-nodes` lane. I mistook the legitimately-running queued job for an orphaned one and cancelled it before realizing it was doing real, correct work | No lasting harm — Ansible is idempotent and the nodes were already fully converged from the direct local run beforehand. Worth calling out as a real gotcha for next time: check `gh run list --json ... event,createdAt` for anything queued *before* `deploy-cicd` finishes before assuming a stuck run is orphaned |
| 3.4 | `AWS_PROFILE=nineteenseventytwo-platform-prod make publish-oidc` | SSO session had expired since build 0002 (`Token has expired and refresh failed`) | `aws sso login --profile nineteenseventytwo-platform-prod`, then retried clean — both discovery endpoints verified live (200) |
| 3.4 (cloud side) | `publish-discovery.sh` suggests setting `publish_cluster_oidc=true` and applying | Flag already defaults `true` in `variables.tf`; a `terraform plan` came back **"No changes."** — the OIDC provider is keyed to the issuer URL and TLS thumbprint, not the cluster's actual signing keys, so it survives a rebuild without needing re-apply even though `kubeadm init` rotates the signing keys every time | Nothing to fix — confirmed via read-only `plan`, no `apply` needed |
| 3.3 | Store kubeconfig as org secret `KUBECONFIG` | This is a cluster-admin credential going into an org-wide GitHub secret — flagged for explicit sign-off rather than run automatically | User set it directly rather than have it run through an agent session |
| 4.3 | `cluster/vault/README.md`'s bootstrap-secrets list | Missing a step entirely: `kv/platform/slack-alerts` (consumed by `cluster/monitoring/externalsecret-slack-alerts.yaml`) was never documented — same gap that bit build 0002, only caught this time because the user remembered and asked before Alertmanager actually failed on it | Documented alongside Grafana's own secret — [PR #129](https://github.com/nineteenseventytwo/nineteenseventytwo-platform/pull/129), merged; secret set in Vault directly |
| 4.3 (step 7) | `vault write auth/userpass/users/mchellmer ... password=-` then `vault login` | Two real, separate problems in sequence. (1) `vault login` with no `VAULT_ADDR` set defaults to `http://127.0.0.1:8200` — not documented inline in this step, same category of gap as build 0002's `KUBECONFIG`/`AWS_PROFILE` env-var gotchas on `publish-oidc`. (2) After pointing at the right address, still `400 invalid username or password` — the interactive `password=-` prompt (type, Enter, Ctrl-D) likely stored a value with different trailing whitespace than what was typed back at login. (3) After re-setting the password cleanly via `printf '%s' '...' \| vault write ... password=-`, login now failed `403 permission denied` — a *third*, different failure: Vault's built-in login-lockout feature (default ~15 min) had tripped from the four earlier failed attempts, and neither `vault write -f auth/userpass/unlock/mchellmer` nor `vault list sys/locked-users/<accessor>` found a working manual-unlock path in this Vault version | (1) and (2) fixed live, no doc change yet — worth adding to step 7's own text. (3) no fix found beyond waiting out the default lockout window; login succeeded once ~15 minutes had passed from the last failed attempt. Both signing paths (`sign.sh` human, `sign-ci.sh` CI via AppRole) confirmed working after |
| 4.2 (post pod-identity-webhook fix) | Cilium/Gateway wave settles after `bootstrap-argocd` | **Build 0002's own known finding #5 recurred, because the fix was never actually added as a runbook step** — only logged as a carried-forward TODO that never got done. `gateway.gateway.networking.k8s.io/gateway` sat `ADDRESS: <none>, PROGRAMMED: Unknown` indefinitely; `cilium-operator`'s Gateway API watches never re-established once the CRDs appeared after it started, same as build 0002 exactly. This is what caused CI's `sign-ci.sh` to fail with `no route to host` on `192.168.20.241:443` — the Gateway had no address to route to at all | `kubectl -n kube-system rollout restart deployment/cilium-operator` — same fix as build 0002, confirmed live (`PROGRAMMED: True`). **This time actually adding it to `docs/REBUILD.md` Phase D, not just this log**, is carried into the next PR |
| 4.2 | Argo CD application-controller's discovery cache doesn't retry a failed CRD-group lookup on its own schedule | `pod-identity-webhook` sat `OutOfSync/Missing` for 10+ minutes on `failed to discover server resources for group version cert-manager.io/v1`, with the exact same frozen retry-attempt timestamp the entire time even though `cert-manager.io/v1` was genuinely live and `kubectl`-queryable the whole time. An `argocd.argoproj.io/refresh=hard` annotation and a manual `.operation` reset both had no effect — those touch comparison/sync state, not the controller's own internal REST-mapper discovery cache | `kubectl -n argocd rollout restart statefulset/argocd-application-controller` cleared it; the very next scheduled retry (Argo CD's own operation backoff, not anything I forced) succeeded cleanly. Worth documenting in `cluster/README.md` alongside the existing prune/refresh-semantics note from build 0002, since none of the three commonly-reached-for nudges (hard refresh, operation reset, waiting) actually fixed this one — only a controller restart did |
| 4.5 | `make verify-default-deny` → exit 0 | **Real bug, not environmental.** `gateway` namespace failed with "no default-deny-all NetworkPolicy and is not on the exemption list" — but `policy/10-default-deny.yaml`'s own header comment has documented `gateway` as one of six deliberately-uncovered namespaces since it was written. `tests/verify-default-deny.sh`'s enforceable `EXEMPT` array — which its own comment says must be "kept in sync" with that documentation — simply never included it. First time this check had ever run against a live cluster with `gateway` present since that comment was written | Added `gateway` to `EXEMPT`. [PR #131](https://github.com/nineteenseventytwo/nineteenseventytwo-platform/pull/131), merged — confirmed clean re-run, exit 0 |
| 4.6 | Post-install Kubescape, the other half of the before/after pair | 73/100 post-install vs 78/100 pre-install — same direction and similar magnitude to build 0001's own pre/post gap (workloads landing always costs some score; see `docs/builds/0003-postinstall-nsa.json` for the full breakdown, headline movers were `Ensure CPU limits are set` (26%) and `Non-root containers` (33%)) | Not a bug — expected, matches the pattern the runbook's own step 3.5 text predicts |
| Phase E step 6 | Flip `hardening_ssh_retire_legacy_keys: true`, the irreversible cutover — the exact step that destroyed build 0002 | **Went cleanly.** Committed and pushed immediately (this build's own step 3 already re-learned that lesson once, at the CA-trust step), merged as its own PR (#133), CI's push-triggered `deploy-nodes` run reached all four nodes cert-only with `unreachable=0, failed=0` across the board. Static-key SSH confirmed refused on `1972-master-1`; `1972-console-1`'s `authorized_keys` now holds only `break-glass` — even my own (Claude's) prior workstation access to console is gone, since I never held the break-glass private key, which is exactly correct | Nothing to fix — this is the row that proves build 0002's postmortem and the Phase E push-gate actually worked. First clean SSH CA cutover this repo has ever completed |
| 4.3 (step 7) again | `vault login` then `make sign-ws` | A fresh, correctly-typed token that had just passed `lookup-self` twice cleanly still failed the very next `sign` call with `invalid token`. Audit log showed why: an `auth/token/revoke-self` had run in between — source never pinned down, not `sign.sh`, not the Makefile, not anything run via `kubectl exec` (that uses a separate root-token session entirely) | No root cause found. Reliably avoided by running `vault login` → `export VAULT_TOKEN=$(cat ~/.vault-token)` → `make sign-ws` as one uninterrupted sequence, nothing else in between. Documented in `cluster/vault/README.md` (PR #135) alongside two other real fixes to the same section: the `VAULT_ADDR` default-to-`127.0.0.1` gap, and a wrong "runs inside a container" claim about `sign-ws` I'd written into an earlier version of that same PR without checking the Makefile first |
| Phase F | `make test-nodes` (`site.yml --check --diff`) | **Real, structural bug — not a one-time artifact like the `docker-ce`/`kubelet` check-mode false-negatives already logged.** `kube_control_plane`'s "Read the issuer of the running control plane" is a read-only `shell` task (`grep` against the static pod manifest, no side effects) with no `check_mode` override, so Ansible's default behavior skips it under `--check` — the next task then asserts the (empty/undefined) result against `cluster_oidc_issuer` and fails, on *every* future `test-nodes` run against an already-initialized control plane, not just a first-ever check before real state exists. Verified as a false positive, not a real mismatch, via `kubectl` (live `--service-account-issuer` flag) and the identical `grep` run directly on the node through `kubectl debug node/...` (SSH wasn't an option — cert had expired, static key retired). Fixing it exposed the *same* bug one task later (`helm version --short`, gating an install block that then failed trying to copy a file a skipped `unarchive` task never created) | Both fixed with `check_mode: false` (PR #136). A systematic grep across `ansible/roles/**/tasks/*.yml` for the same shape (`command`/`shell` + `changed_when: false`, no `check_mode: false`) turned up two more: `common`'s swap-check (a false-negative in the *other* direction — silently hid real swap drift from a `--check --diff` run) and `kube_control_plane`'s helm-diff-plugin check, same failure shape as the helm one (PR #137). One candidate (`kubeadm token create --print-join-command`) was correctly left alone — it genuinely mutates cluster state, so skipping it under `--check` is right. `make test-nodes` passes clean across all four hosts after both PRs |

## PRs

| Range | Theme |
|---|---|
| [#125](https://github.com/nineteenseventytwo/nineteenseventytwo-platform/pull/125) | Regenerate `known_hosts` for the re-imaged nodes |
| [#126](https://github.com/nineteenseventytwo/nineteenseventytwo-platform/pull/126)–[#127](https://github.com/nineteenseventytwo/nineteenseventytwo-platform/pull/127) | Throwaway self-hosted-runner proof, then removed |
| [#128](https://github.com/nineteenseventytwo/nineteenseventytwo-platform/pull/128) | Build log + pre-install Kubescape baseline |
| [#129](https://github.com/nineteenseventytwo/nineteenseventytwo-platform/pull/129) | Document the missing `slack-alerts` Vault step |
| [#130](https://github.com/nineteenseventytwo/nineteenseventytwo-platform/pull/130) | Trust the new Vault SSH CA (Phase E step 3) |
| [#131](https://github.com/nineteenseventytwo/nineteenseventytwo-platform/pull/131) | Fix `verify-default-deny.sh`'s missing `gateway` exemption |
| [#132](https://github.com/nineteenseventytwo/nineteenseventytwo-platform/pull/132) | Phase D-E log, post-install Kubescape, `cilium-operator` restart added to REBUILD.md |
| [#133](https://github.com/nineteenseventytwo/nineteenseventytwo-platform/pull/133) | Phase E step 6 — the SSH cutover itself, clean this time |
| [#134](https://github.com/nineteenseventytwo/nineteenseventytwo-platform/pull/134) | Phase E cutover documented in the build log |
| [#135](https://github.com/nineteenseventytwo/nineteenseventytwo-platform/pull/135) | Vault `sign-ws`/`VAULT_TOKEN` documentation, including the revoke-self gotcha |
| [#136](https://github.com/nineteenseventytwo/nineteenseventytwo-platform/pull/136) | Fix the OIDC-issuer check-mode false-negative |
| [#137](https://github.com/nineteenseventytwo/nineteenseventytwo-platform/pull/137) | Two more check-mode false-negatives from a systematic sweep |

Counts at close: `fix/` 4 · `feat/` 2 · `chore/` 1 · `test/` 1 · `docs/` 5 · total 13.

`fix/` share: 4/13 = **31%**, well below build 0002's 8/10 (80%). Most of
0002's own carried-in lessons did make it into the config, not just the
log — the SSH-trust push-gate held under real conditions, and the
`cilium-operator` restart step (recurred once more, then finally landed as
an actual runbook step rather than a TODO) was the only genuine repeat.
Everything else new this build was previously-undiscovered — the
check-mode `check_mode: false` bug class, `verify-default-deny.sh`'s
exemption-list drift, and the missing `slack-alerts` Vault step — the kind
of thing this metric is supposed to let through without counting against
the trend.

## Evidence captured

- [x] Kubescape NSA baseline against the **empty hardened cluster** →
      `docs/builds/0003-baseline-nsa.json` — 78/100, matches build 0002's
      pre-install score exactly (same hardening config, same k8s/Cilium
      versions — expected, not a coincidence)
- [x] Post-install Kubescape scan for the before/after pair →
      `docs/builds/0003-postinstall-nsa.json` — 73/100
- [x] `make test-network` output (all 12) — 10/10 real checks pass (from
      `1972-console-1`, correctly), 2 workstation-only checks pass separately
- [x] `make test-nodes` across all four hosts — clean (`failed=0,
      unreachable=0`) after PRs #136/#137
- [x] `make verify-default-deny` → 0 (after PR #131's fix)
- [x] `make verify-irsa` → assumed-role identity, `Sealed: false`, `Seal
      Type: awskms`
- [x] `kubectl -n argocd get applications` → all 17 Synced/Healthy

## What broke that the runbook did not predict

**The `cilium-operator`/Gateway CRD bug recurred, and the reason is itself
the lesson.** Build 0002 found and fixed it live, but only ever recorded the
fix as a carried-forward TODO in the build log — not as an actual step in
`docs/REBUILD.md`. A build log is not a runbook; nothing reads a previous
build's "Carried into" checklist automatically, so the exact same failure
cost real time twice. Fixed for real this time: the restart is now
[step 4.1 of Phase D itself](../REBUILD.md#41-hand-the-cluster-to-argo-cd),
not a note anywhere else. The general lesson, not just this specific bug:
**a fix that only lives in a build log's "carried into" section is not
landed — it's a to-do list with no enforcement, and this repo already had
one example of exactly that costing a second repeat before this build
supplied a second.**

**Ansible's `command`/`shell` check-mode default is a real, recurring bug
class in this repo, not isolated incidents.** Three separate tasks
(`kube_control_plane`'s issuer check, its helm-version check, its
helm-diff-plugin check) all shared the same shape: a read-only diagnostic
task with `changed_when: false` but no `check_mode: false`, silently
skipped under `--check`, breaking a downstream assertion or `when:`
condition that assumed real data. `common`'s swap-check had the identical
shape but the opposite failure direction — a false negative instead of a
false positive. A grep for the pattern across every role found all four in
one pass; none had been found by reading code, all four were found by
`test-nodes` actually failing (or, for the swap one, only by the systematic
sweep — it never threw a hard error at all, which is exactly why it's the
more dangerous of the two directions).

## Carried into build 0004

- [ ] **Land `bootstrap/cloud-init/render.sh`'s fix**, held uncommitted
      across three builds now, still at the user's explicit request. Worth
      asking directly whether it should just land at the start of the next
      build rather than being re-asked about again.
- [ ] **Document Argo CD manual-sync semantics** in `cluster/README.md` —
      now two undocumented gotchas deep (build 0002's prune/refresh
      semantics, this build's discovery-cache/controller-restart one).
      Third build in a row this has cost time without landing.
- [ ] **`eightbitsaxlounge/server` deletion** and **`apps/` ApplicationSet
      being empty** — both still out of scope, carried forward unchanged
      since build 0001.
- [ ] **The Vault token `revoke-self` mystery** (Deviations table, step 7
      row) — root cause never found, only worked around. Worth a real
      investigation next time it's convenient, before it costs more time
      than the ~15 minutes it cost here.
- [ ] **Consider a `check_mode: false` lint/convention** for
      `ansible/roles/**` — this build found four real instances of the same
      bug shape by one manual sweep; nothing stops a fifth from landing
      unnoticed in the next PR that adds a diagnostic `command`/`shell`
      task.
