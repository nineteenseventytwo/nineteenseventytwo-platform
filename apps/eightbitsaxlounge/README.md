# eightbitsaxlounge

Six services, migrated out of the `eightbitsaxlounge/server` Ansible layer
under ADR-0012, in dependency order: `db` → `state` → `data` → `midi` →
`overlay` → `chat`.

## Only one environment runs at a time

`dev` and `prod` are mutually exclusive. The parked one has `replicas: 0`
committed on every workload; the live one has the values in the table below.
Two reasons, and the first is not a capacity argument:

1. **`chat` would double-respond.** Both environments' bots authenticate as
   the same Twitch bot account and listen to the same channel
   (`twitch_channel` is identical in both ConfigMaps — it is one real
   channel, not a per-environment one). Run both and every `!command` gets
   answered twice, and every resulting MIDI change is sent twice.
2. **The nodes are 2 GB Raspberry Pis.** Both environments online is ~1 GB of
   requests against ~3.3 GB allocatable per node, which is what pushed
   `vault-0` and `eightbitsaxlounge-prod`'s `state-0` into `Pending` on
   2026-09-10 — the platform's own Vault went down because a tenant filled
   the schedulable memory.

`prod` is only needed while a stream is scheduled. The normal state is `dev`
online, `prod` parked; flip for a stream, flip back after.

## Online replica values

Restore these when bringing an environment back up — `data` is the one that
is not 1, and flattening it to 1 on the way back is an easy mistake.

| Workload | Kind | Online replicas |
|---|---|---|
| `db` | Deployment | 1 |
| `state` | StatefulSet | 1 |
| `data` | Deployment | 2 |
| `midi` | Deployment | 1 |
| `overlay` | Deployment | 1 |
| `chat` | Deployment | 1 |

## Flipping

Edit `replicas:` in the six `*-deployment.yaml`/`*-statefulset.yaml` files of
each environment and open a PR — not `kubectl scale`, which Argo CD reverts
on its next sync (the Applications have `syncPolicy.automated` with
self-heal; an imperative scale is drift, and it is treated as drift).

PVCs are deliberately left in place while parked: `db`'s CouchDB data and
`chat`'s `/app/tokens/tokens.db` (the Twitch OAuth refresh tokens) both have
to survive the flip. Parking is `replicas: 0`, never deleting the directory
from the ApplicationSet generator — that would prune the PVCs with
everything else and cost a full re-authorisation of both Twitch accounts.
