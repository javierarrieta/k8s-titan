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

## What still has to happen, in order

1. **`du -sh /opt/data` on the techdelivery host, and write the number here.** `local-path-retain`
   sets `allowVolumeExpansion: false` (`apply/20-infra/storage-retain.yaml`), so the 10Gi request is
   not a soft target — if the tree is bigger, the fix is PV surgery, not a resize.
2. merge. The PVC binds, the pod schedules, the app boots against empty state — harmless, and it
   does mean the first minutes of cron runs are against nothing.
3. rsync the old `/opt/data` into `/var/lib/rancher/k3s/storage/apps_investing-agent-pv-claim_*`,
   then `chown -R 10000:10000`. The pod is uid/gid 10000 with fsGroup 10000; a tree owned by
   anything else reads as a corrupt DB.
4. `kubectl -n apps delete pod -l app=investing-agent`. The running pod holds the old files open,
   so a copy that lands underneath it is not picked up until the process restarts. Not
   `kubectl scale` — replicas is git-managed and Flux reverts it at the next sync.
5. prove it: the dashboard answers through the Service (`http://investing-agent.apps.svc`), one
   cron run completes, and the DB is not reported corrupt.

`make dry-run` was on this list. It has been run and passed; see the table above.

## Not proven

- **the migrated state works.** Steps 2-5 are that proof and none of them have run. Until they do,
  this PR is a manifest the API server accepts, not a working migration. Server-side dry-run
  proves admission, not runtime: it has never seen the pod schedule, the volume bind, or SQLite
  open the restored tree.
- **nothing here is backed up.** techdelivery protected this claim with the `backup-investing-agent`
  restic CronJob; titan ships no generic PV backup (AGENTS.md, "Backups"). Accepted in PR #162 as a
  decision, not an oversight — closing it is its own change.
- **a gateway that is alive but wedged is invisible.** It exposes no health endpoint, so nothing can
  probe it. `exec` fixed the *dead* gateway; wedged is still dark.
- **cold start against a restored 10 Gi is unmeasured.** The startupProbe allows ~5 minutes, which
  is generous on purpose; if that turns out to be far too much, tighten it from a measurement rather
  than a guess.
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

## Known gate gap this migration exposed

Nothing checks that a hand-written Deployment's `envFrom.secretRef.name` resolves to a Secret that
exists. `make release-secrets` walks `HelmRelease` objects only — its own output says so — and
`make secrets-placement` proves placement, encryption and listing, never consumers. A typo'd name
builds green and produces a Pending pod naming a Secret that plainly exists, which is the same
failure this PR had to reason about for the ciphertext. The name here was checked by hand against
`apply/10-secrets/investing-agent-secrets.yaml`. Closing it properly is a gate change of its own,
with an allow-list for in-cluster-produced Secrets (`titan-tls`, `coder-tls`, `tesla-streaming-tls`,
`postgres-exporter-credentials`), not a line added to a migration PR.
