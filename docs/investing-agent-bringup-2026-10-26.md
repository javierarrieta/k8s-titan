# Investing-agent (hermes) bring-up on titan — 2026-10-26

Hermes, the Nous Research investing agent, moved out of `../k8s-techdelivery` into this cluster:
namespace `apps`, object names unchanged, image pin unchanged. The manifest is
`apply/50-apps/investing-agent/investing-agent.yaml` and its header is the **design** — why
`apps`, why `local-path-retain`, why the Secret had to be re-encrypted. This file is the **log**:
what was measured before merging, what has run, and what is still unproven. Read the header for
*why*; read here for *did*.

## Measured before merging

| claim | evidence |
|---|---|
| every offline gate passes on the branch | `make check` on `feat/investing-agent`: leak-check, kustomize-check, kustomize-listing, `validate`, secrets-placement, release-secrets, db-url-check, oidc-check, grafana/observability/open-webui-oidc-check, mealie-check, sure-check, crd-check (39 objects), namespace-check (201 objects), tesla-forwarder-tests — all green |
| the re-encrypted Secret actually decrypts | `make validate` → `OK: apply/10-secrets/investing-agent-secrets.yaml` with the Coder workspace age key. 5 recipients, `titan-k8s` `age1t5z4e…` present, techdelivery's cluster key absent |
| nothing was dropped in the re-encryption | key set compared against `../k8s-techdelivery`'s own file: `OPENAI_BASE_URL`, `HERMES_DASHBOARD_BASIC_AUTH_USERNAME`, `HERMES_DASHBOARD_BASIC_AUTH_PASSWORD_HASH` — three keys, same names, both sides |
| the source is stopped before this starts | k8s-techdelivery PR #171 (`scale to 0`) merged `2026-10-26T07:39:02Z`, before this branch's head commit. There is no window in which both gateways run. |
| the image pin is real, and the semver move is still ahead of us | Docker Hub API on `/v2/repositories/nousresearch/hermes-agent/tags/v2026.9.24/` returns the tag (amd64, 968 MB); `v0.22.5` also answers 200 |
| the new process tree does what its comment claims | 14 assertions against a fake `hermes`, run under both `sh` and `bash`: both children start; after `exec` the container PID *is* the gateway; SIGTERM reaches the gateway and the container is gone in <20 ms; a gateway crash exits the container non-zero ~1 s later; a dashboard death does **not** end the container, which is exactly why the liveness probe is load-bearing. The old `… & wait` form was run for comparison and did stay Running with a dead gateway. |
| the source volume's real host path | `kubectl get pv -o custom-columns=…` on the techdelivery host: `investing-agent-pv-claim` → `/opt/k3s/volumes/pvc-21879166-bb63-4c16-a2d2-9f99120058d4_apps_investing-agent-pv-claim`. **Not `/opt/data`** — that is the *container* mount path, and the first `du -sh` measured a different directory entirely. The source cluster's `local-path` uses `nodePathMap: /opt/k3s/volumes`, not the k3s default `/var/lib/rancher/k3s/storage` |
| the source tree fits the claim | `du -sh` on the path that PV names, 2026-10-26: **161M** against a 10Gi claim — roughly 64x headroom. The claim is the source's own value and was kept rather than trimmed, because `allowVolumeExpansion: false` makes trimming irreversible |
| the live API server accepts every object in the tree | `make dry-run DRYRUN_CONTEXT=<admin>`, 2026-10-26, on the rebased branch: `00-bootstrap ok (56)`, `10-secrets ok (33)`, `20-infra ok (29)`, `40-certificates ok (3)`, `50-apps ok (73)` — 5 stages built, 5 accepted. This is the first live validation of the new PVC and Deployment, and the first time that gate reached `50-apps` in weeks |
| the built object is what was written | `kubectl kustomize apply/50-apps` → `Deployment apps/investing-agent` replicas 1, `strategy: Recreate`, `terminationGracePeriodSeconds: 60`, readiness + startup + liveness all present, PVC on `local-path-retain` |

## What the dry-run caught on the way

The first attempt did not pass. It stopped at `10-secrets` with
`failed to convert new object (apps/investing-agent-secrets; /v1, Kind=Secret): illegal base64
data at input byte 3`, and named `llm/llm-bearer-token` alongside it. A Secret's `data:` values
are base64 by contract and a sops ciphertext is not base64, so the API server refuses the tree
while it is still encrypted — Flux decrypts before it applies, so only this gate ever sees it.

Three things came out of that one error:

- this Secret moved to `stringData` (values byte-identical, compared per key by sha256);
- `llm-bearer-token` had the same defect on main and had been silently blocking the gate for
everything behind it — fixed in PR #166, which is what let `20-infra` onwards be checked at all;
- `secrets-placement` now rejects `data:` under `apply/10-secrets`, so it cannot come back.

## Pre-flight: the size, and the wrong directory it took to get it

`/opt/data` is what the container mounts, not where the source cluster keeps the bytes. The first
`du -sh /opt/data` returned 11M and measured something else — the operator's instinct was right,
and the PV listing settled it:

```
CLAIM: investing-agent-pv-claim
PATH:  /opt/k3s/volumes/pvc-21879166-bb63-4c16-a2d2-9f99120058d4_apps_investing-agent-pv-claim
du -sh <that path>  ->  161M
```

161M against a 10Gi claim, so the `allowVolumeExpansion: false` trap is not a live risk and the
copy is a seconds-long transfer, not one to schedule. The lesson is in the method: with
`local-path`, a volume's host path is derived from a random PV name and a cluster-specific
`nodePathMap`, so it is read off the PV object and never guessed from the mount path.

## What still has to happen, in order

1. merge. The PVC binds, the pod schedules, the app boots against empty state — harmless, and it
   does mean the first minutes of cron runs are against nothing.
2. rsync **from the source PV's host path** —
   `/opt/k3s/volumes/pvc-21879166-bb63-4c16-a2d2-9f99120058d4_apps_investing-agent-pv-claim` on the
   techdelivery host — into titan's directory for the claim, **read off titan's own PV** after it
   binds (`kubectl --context titan get pv -o custom-columns=CLAIM:.spec.claimRef.name,PATH:.spec.local.path`)
   rather than globbing a guessed name — then `chown -R 10000:10000`. The pod is uid/gid 10000 with fsGroup 10000; a tree owned by
   anything else reads as a corrupt DB. The two clusters use different `nodePathMap` roots
   (`/opt/k3s/volumes` there, `/var/lib/rancher/k3s/storage` here) and the directory name embeds
   the PV name, which is random — so neither end of this copy can be named in advance. Read both
   off their PV. The container path `/opt/data` appears in neither.
3. `kubectl -n apps delete pod -l app=investing-agent`. The running pod holds the old files open,
   so a copy that lands underneath it is not picked up until the process restarts. Not
   `kubectl scale` — replicas is git-managed and Flux reverts it at the next sync.
4. prove it: the dashboard answers through the Service (`http://investing-agent.apps.svc`), one
   cron run completes, and the DB is not reported corrupt.

`make dry-run` and the `du -sh` pre-flight have both been done; see the table above.

## Not proven

- **the migrated state works.** Steps 1-4 are that proof and none of them have run. Until they do,
  this PR is a manifest the API server accepts, not a working migration. Server-side dry-run
  proves admission, not runtime: it has never seen the pod schedule, the volume bind, or SQLite
  open the restored tree.
- **nothing here is backed up.** techdelivery protected this claim with the `backup-investing-agent`
  restic CronJob; titan ships no generic PV backup (AGENTS.md, "Backups"). Accepted in PR #162 as a
  decision, not an oversight — closing it is its own change.
- **a gateway that is alive but wedged is invisible.** It exposes no health endpoint, so nothing can
  probe it. `exec` fixed the *dead* gateway; wedged is still dark.
- **cold start against the migrated tree is unmeasured, but the tree is 161M**, so the startupProbe's
  ~5 minutes is ample by a wide margin. If the pod ever fails to become Ready, the volume is not why.
- **why `gateway.lock` ever goes stale is unknown.** The manifest deletes it on every start, which
  was inherited from the source without anyone recording the failure it papers over. With the gateway
  now at PID 1 a crash restarts the pod cleanly, so if the lock turns out to have been guarding
  nothing, deleting it unconditionally is what lets a half-started gateway look healthy. Worth one
  look at the techdelivery logs before the source teardown removes the evidence.
- **`/bin/sh` inside the image is assumed, not inspected.** It is proven by the source pod having run
  the same `command` for months, which is decent evidence but not the same kind.
- **the 512Mi `emptyDir` at `/tmp` is a hard cap whose failure mode is eviction, not an error.** If
  SQLite FTS spill grows into it, kubelet evicts the pod and on a single node that takes the gateway
  with it.

## Gate gap this migration exposed — closed

Nothing used to check that a hand-written Deployment's `envFrom.secretRef.name` resolves to a Secret
that exists. `make release-secrets` walks `HelmRelease` objects only, and `make secrets-placement`
proves placement, encryption and listing, never consumers. A typo'd name built green and produced a
Pending pod naming a Secret that plainly exists.

`make secret-refs` (#165) closes it: `envFrom`, `secretKeyRef`, volume mounts and the protected-Secret
references of every hand-written workload, with an allow-list for in-cluster-produced Secrets that is
`apps/titan-tls` and nothing else.

## Live edits made inside the volume, 2026-10-26

**Why this section exists.** Git pins an image, three env vars and a PVC. Everything hermes actually
does is decided by files inside the claim — `config.yaml`, two `.env` files, a profile tree — and no
gate in this repo can see any of them. Every check stayed green while two of those files were wrong.
Anyone who copies this volume inherits all of the below silently, which is why it is written down
rather than left in a terminal scrollback.

| file | change | why | backup | proof it took |
|---|---|---|---|---|
| `profiles/invest/config.yaml` | `model.default` `Qwopus3.6-35B` → `halogen-qwen3.8-flash-next`; `model.base_url` `:8001` → `:8731` | `:8001` is decommissioned. `:8731` serves exactly one model, so the id was not a free choice — `/v1/models` returned `['halogen-qwen3.8-flash-next']` | `config.yaml.bak-20261026` | gateway up, and a conversation completed over Discord |
| `profiles/invest/.env` | `DISCORD_BOT_TOKEN` commented out | the token there was revoked at Discord; replacing it with `default`'s live token produced `Profile 'default' and 'invest' both configure discord with the same credential — refusing to start the duplicate`. `discord:` in that config has no `enabled:` key, so the token's presence is the switch | `.env.bak-20261026` | `gateway_state.json`: `discord.state: connected`, `served_profiles: [default, invest]` |
| `.hermes/.env.backup` | moved out of the volume; `ls "$HERMES_HOME"/.env*` no longer lists it. Intended destination `/root/hermes-env-backup-2026-10-26` on the titan host — not re-verified from here | held superseded tokens that made token-shaped grep forensics ambiguous — three matches, two of them dead ghosts | `/root/hermes-env-backup-2026-10-26` (unverified) | `ls "$HERMES_HOME"/.env*` no longer lists it |
| `.hermes/active_profile` | created, then removed | experiment: making `invest` the launch profile. The gateway refused to start — `invest` was never folded into multiplex — and the pod crash-looped seven times | n/a, deleted | absent; pod healthy |
| `profiles/invest/.env` ownership | restored to `hermes:hermes` | `kubectl exec` runs as root, so a file rewritten that way changes owner | n/a | `ls -la` shows `hermes hermes` |

**Pre-existing, not from today:** `.hermes/.env.new` (18 B) and `.hermes/.env.tmp` (309 B), both dated
May 29 — leftovers from someone's earlier in-place edit. They are credential-shaped files sitting next
to the real one and are worth deleting on purpose rather than by accident.

**What to re-check after any future copy of this volume.** The failure mode that bit was a service
moving and a profile config not following it, which is invisible from outside and silent from inside:
the pod is Ready, the dashboard answers, cron runs, and every model call fails.

Read the endpoint the profile itself names, then ask it, and confirm the platform state:

```
kubectl --context titan -n apps exec deploy/investing-agent -- sh -c 'grep -A4 "^model:" "$HERMES_HOME/profiles/invest/config.yaml"'
kubectl --context titan -n apps exec deploy/investing-agent -- sh -c 'grep -o "\"state\": \"[a-z]*\"" "$HERMES_HOME/gateway_state.json"'
```

Then curl the `base_url` that first command printed, at `/v1/models`, and expect `200`. Three
commands, and they are the only ones that would have caught anything this section documents.


