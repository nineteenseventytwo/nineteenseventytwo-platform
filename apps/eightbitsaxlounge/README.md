# eightbitsaxlounge

Six services, migrated out of the `eightbitsaxlounge/server` Ansible layer
under ADR-0012, in dependency order: `db` → `state` → `data` → `midi` →
`overlay` → `chat`.

## `dev` and `prod` both run, all the time — except `chat`

Every workload except `chat` runs in both environments simultaneously, each
at the replica count in the table below. Each environment's `db`/`state`/
`data`/`midi`/`overlay` are fully namespace-isolated from the other's — two
CouchDBs, two NATS instances, two device connections to the PC on different
ports (`5000` dev, `5001` prod) — so there is nothing to conflict.

`chat` is the one exception, because it is the one layer with genuinely
shared state across environments: there is no such thing as a "dev Twitch
channel" to isolate against. Both environments' bots authenticate as the
same Twitch bot account, share one EventSub conduit, and listen to the same
real channel (`twitch_channel` is identical in both ConfigMaps). Run both
`chat` Deployments at once and every `!command` gets answered twice, and
every resulting MIDI change gets sent twice.

**Only one of `dev`/`prod`'s `chat` runs at a time.** Toggle it with the
[**"Chat Set Active Environment"**](https://github.com/nineteenseventytwo/nineteenseventytwo-eightbitsaxlounge/actions/workflows/chat-set-environment.yaml)
GitHub Actions workflow in `nineteenseventytwo-eightbitsaxlounge` — pick
`dev` or `prod` from the dropdown and run it. It scales the target
namespace's `chat` to 1 and the other's to 0 via `kubectl`, live, in about a
minute. No manifest edit, no PR, no direct cluster access.

That toggle is intentionally *not* GitOps — `chat`'s replica count is the
one thing in this repo that changes outside of a commit. It works because
`cluster/argocd/applications/100-apps.yaml`'s ApplicationSet template
carries an `ignoreDifferences` entry naming `Deployment/eightbitsaxlounge-
chat`'s `/spec/replicas` specifically: Argo's `selfHeal` still enforces
everything else about the Deployment (image, secrets, resources — a real
git change to any of those still lands normally), it just never touches
that one field. Whatever the workflow last set stays set until the workflow
runs again.

### Before 2026-09-12

Every workload used to flip together — the whole of `prod` parked at
`replicas: 0` while `dev` was live, and vice versa, via a PR editing all
twelve manifests. That model existed for a capacity reason that no longer
holds (see below), not a correctness one: `chat` was always the only
workload that actually needed exclusivity.

## Capacity: how both environments' `db`/`state`/`data` fit

The 2 GB-node capacity problem this model exists to avoid is real — doubling
every workload's memory once pushed `vault-0` and `eightbitsaxlounge-prod`'s
`state-0` into `Pending` on 2026-09-10, taking the platform's own Vault down
because a tenant filled the schedulable memory on the two worker nodes. Two
things changed since then that make running both environments' non-`chat`
workloads affordable:

1. **`midi` and `overlay` tolerate the control-plane node** now (both
   Deployments, both environments) — they're stateless, so they carry none
   of the Longhorn-CSI-absent-on-`1972-master-1` restriction that keeps
   `db`/`state`/`data` worker-only (see `cluster/longhorn/values.yaml`'s
   `systemManagedComponentsNodeSelector`, "Worker SSDs only"). Moving all
   four `midi`+`overlay` pods (both envs) off the workers is what buys the
   headroom for `db`/`state`/`data` to double up on them instead.
2. **The control-plane node itself has spare capacity** — see PR #164's
   reasoning for letting `argocd`/`monitoring`/`longhorn-ui` schedule there
   too. `1972-master-1` sat at ~592Mi requested out of ~3.3Gi allocatable
   before any of this, almost entirely idle.

Net effect on the two worker nodes: doubling `db`+`state`+`data` costs
~320Mi; moving both environments' `midi`+`overlay` off them frees ~128Mi.
The two nearly cancel out — worker memory utilization stays in the same
85–90% range it was already safely running at with one environment online,
rather than climbing toward the ceiling that caused the 2026-09-10 outage.
This is close enough to the edge that it is worth re-checking before adding
anything else to this tenant.

## Online replica values

| Workload | Kind | Dev | Prod |
|---|---|---|---|
| `db` | Deployment | 1 | 1 |
| `state` | StatefulSet | 1 | 1 |
| `data` | Deployment | 2 | 2 |
| `midi` | Deployment | 1 | 1 |
| `overlay` | Deployment | 1 | 1 |
| `chat` | Deployment | toggle | toggle |

`chat`'s two Deployments are committed at whatever the last toggle left
them (one at 1, one at 0) — that's runtime state now, not a value to "fix"
back to some canonical committed pair. Everything else stays at the values
above in both environments permanently; there's no more "restore this
after a flip" step for them.

## PVCs

`db`'s CouchDB data and `chat`'s `/app/tokens/tokens.db` (the Twitch OAuth
refresh tokens) exist per environment and are never touched by the `chat`
toggle — only its replica count changes, so both environments' tokens stay
valid across any number of toggles. Never delete an environment's directory
from the ApplicationSet generator to "park" it — that prunes its PVCs along
with everything else and costs a full re-authorisation of both Twitch
accounts for that environment.
