# Build 0003 — SSH cutover retry

**Dates:** 2026-09-04 → *(open)*
**Runbook followed:** [`docs/REBUILD.md`](../REBUILD.md) @ `55e1e69`
**Target versions:** k8s `1.37.0`, etcd `3.7.1-0`, Cilium `1.20.1`
**Outcome:** *(open)*

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

- [ ] **Prove the runbook end to end, including Phase E and F.** 0002's
      original purpose, still unmet.
- [ ] **Land `bootstrap/cloud-init/render.sh`'s fix.** Held uncommitted
      through all of 0002; still correct, still not on `main`.
- [ ] **Land `render.sh` and any future SSH-trust-affecting fixes in their
      own PR immediately**, not batched with other work — the direct lesson
      from 0002's failure, applied proactively this time.
- [ ] **Note the check-mode false-negative** (`docker-ce`/`kubelet` "no
      package matching" under `CHECK=1`) somewhere steps 1.3/3.2 can warn
      about it.
- [ ] **Document Argo CD manual-sync semantics** (`prune: true` not
      inherited by manual `operation.sync`; identical-content patches are
      no-ops) in `cluster/README.md`.
- [ ] **Add the `cilium-operator` restart step explicitly to Phase D**,
      right after `bootstrap-argocd`.
- [ ] **Kubescape post-install pair** — only the pre-install half exists
      from 0002; capture both this time.
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

## PRs

| Range | Theme |
|---|---|
| [#125](https://github.com/nineteenseventytwo/nineteenseventytwo-platform/pull/125) | Regenerate `known_hosts` for the re-imaged nodes |
| [#126](https://github.com/nineteenseventytwo/nineteenseventytwo-platform/pull/126)–[#127](https://github.com/nineteenseventytwo/nineteenseventytwo-platform/pull/127) | Throwaway self-hosted-runner proof, then removed |
| [#128](https://github.com/nineteenseventytwo/nineteenseventytwo-platform/pull/128) | Build log + pre-install Kubescape baseline |
| [#129](https://github.com/nineteenseventytwo/nineteenseventytwo-platform/pull/129) | Document the missing `slack-alerts` Vault step |
| [#130](https://github.com/nineteenseventytwo/nineteenseventytwo-platform/pull/130) | Trust the new Vault SSH CA (Phase E step 3) |
| [#131](https://github.com/nineteenseventytwo/nineteenseventytwo-platform/pull/131) | Fix `verify-default-deny.sh`'s missing `gateway` exemption |

Counts so far: `fix/` 2 · `feat/` 1 · `chore/` 1 · `test/` 1 · `docs/` 2 · total 7.

Compare the `fix/` share against build 0002's 8/10 (80%). Anything at or
above that, on a rebuild that starts from a runbook 0002 already corrected
through Phase D, means this log's own carried-in items did not actually make
it into the config.

## Evidence captured

- [x] Kubescape NSA baseline against the **empty hardened cluster** →
      `docs/builds/0003-baseline-nsa.json` — 78/100, matches build 0002's
      pre-install score exactly (same hardening config, same k8s/Cilium
      versions — expected, not a coincidence)
- [x] Post-install Kubescape scan for the before/after pair →
      `docs/builds/0003-postinstall-nsa.json` — 73/100
- [x] `make test-network` output (all 12) — 10/10 real checks pass (from
      `1972-console-1`, correctly), 2 workstation-only checks pass separately
- [ ] `make test-nodes` across all four hosts
- [x] `make verify-default-deny` → 0 (after PR #131's fix)
- [x] `make verify-irsa` → assumed-role identity, `Sealed: false`, `Seal
      Type: awskms`
- [x] `kubectl -n argocd get applications` → all 17 Synced/Healthy

## What broke that the runbook did not predict

The section the next build actually reads. One entry per surprise: the symptom,
why it was not obvious, and — most importantly — **where the fix landed** so it
cannot recur. A fix that landed only in this log is not a fix.

## Carried into build 0004

- [ ]
