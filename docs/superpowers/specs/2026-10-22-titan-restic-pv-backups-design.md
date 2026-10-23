# titan restic PV backups — design

Status: **proposed, not implemented.** Scope fixed by the operator on 2026-10-22: **PVCs only, no
S3-to-S3 mirror of the oCIS blob bucket, because casa's MinIO has no capacity to hold a second copy
of it.** The restic repository itself does fit — the constraint is the blob mirror specifically.
That decision removes oCIS from coverage entirely, for the reason in §4.

The deferred trigger. `2026-10-03-k8s-titan-flux-bootstrap-design.md` §13b deferred the generic
PV stream "until a workload with data that is not that database arrives", and recorded that the
override was compensated only because CNPG carries its own backup path. That trigger has now fired
a third time and the compensation no longer covers it: `files/ocis-data` holds a user's driving
history-adjacent file store, `coder-workspaces` holds 40Gi of workspace homes, and both are data
that CNPG's base backups do not touch. The deferral is spent.

The mechanism is not invented here. It is a port of `k8s-techdelivery/apply/30-backup/`, which has
been running on the OVH VPS, has a written restore procedure, has alerts that were induced and
observed to fire, and carries the accumulated scars — the nightly connectivity blackout, the
`AccessDenied`-not-`NoSuchBucket` trap, the `fsGroup` trap, the prune-eating-a-volume incident
(repo Issue #13). Read that `README.md` before this one; it explains several choices that would
otherwise look arbitrary.

## 1. Direction, and why the port is close to a copy

titan is an OVH single-node k3s box backing up to casa's MinIO over the WireGuard mesh. That is
the same direction as techdelivery → casa MinIO, so the failure domains are already independent
(OVH vs home LAN) and the transport is already proven: **oCIS writes object data to
`http://192.168.0.6:9000` today and has done since it was deployed**, which is a stronger
reachability proof than any pre-flight curl.

Two things differ from techdelivery and both matter:

- titan's Postgres is CNPG, not Databasus. CNPG already ships base backups and continuous WAL to
  S3, drilled for both full restore and PITR (`docs/authentik-runbook.md` §2). So the database PV
  is excluded for the same *reason* techdelivery excludes it, under a different owner.
- titan has a workload whose persistent state is split across two stores that must be restored
  together. That is §4, and it is the only genuinely new problem here.

## 2. Coverage

Live inventory as measured 2026-10-22 (`kubectl get pvc -A`, `kubectl get pv`):

| PVC | Size | StorageClass | Backed up here | Why |
|---|---|---|---|---|
| `files/ocis-data` | 5Gi | `local-path-retain` | **no — see §4** | backing up the metadata tree without the blob bucket produces a restore that looks healthy and is corrupt |
| `coder-workspaces/coder-*-home` | 40Gi | `local-path-retain` | **yes** | workspace homes; the trigger the coder spec named |
| `open-webui/open-webui-data` | 10Gi | `local-path-retain` | **yes** | uploads and local index; the relational half is in CNPG |
| `observability/grafana-data` | 1Gi | `local-path-retain` | **yes** | dashboards/provisioning not in git |
| `apps/tesla-grafana` | 1Gi | `local-path` | **yes** | same |
| `databases/postgres-1` | 10Gi | `local-path` | **no** | CNPG owns it. A file-level copy of a live Postgres datadir can restore corrupt. CNPG's own path is drilled. |

~51Gi of source, excluding Postgres and excluding oCIS.

Two PVs need a decision before they are silently ignored: `coder-home-recovered` and
`pvc-2a10168c-…`, both 40Gi in `coder-workspaces`, neither bound to a live PVC as far as the
`pvc -A` listing shows. They are named here so they are not discovered later. If they are stale
recovery staging, they should be deleted, not backed up.

## 3. Stage shape, and the two settings that are not interchangeable

New top-level stage `apply/30-backup/` with its own `kustomization.yaml`, its own
`apply/00-bootstrap/stage-backup.yaml`, and an entry in `00-bootstrap/kustomization.yaml` — the
one-directory-one-Kustomization-one-failure-domain rule from `AGENTS.md`. It is not a subdirectory
of `50-apps`.

`prune: false` **and** `deletionPolicy: Orphan`, both required, for the reason techdelivery
documents: `Orphan` governs only deletion of the Kustomization object, while `prune: true` still
deletes individual manifests removed from git. The property wanted is "a GitOps accident cannot
delete the thing that guards against the accident", which needs both. Consequence accepted in
advance: removing a backup job deliberately requires `kubectl delete cronjob`, not a commit.

Secret in `apply/10-secrets/backup-minio-secrets.yaml`, sops-encrypted, `stringData:` — the
`data:` form fails server-side apply on ciphertext, learned the hard way in this repo's own oCIS
bring-up. `make secrets-placement` and `release-secrets` already enforce the listing and the
namespace.

restic and the restore image pinned **by digest, never a floating tag**, matching techdelivery's
rule and its recorded reason: the restore image's CI caught `restic snapshots --last 1` silently
misparsing in 0.19.x, which made every tag-based restore exit 3 claiming no snapshot existed. A
floating tag re-imports that class of failure.

## 4. oCIS is out of scope, and that means oCIS has no backup

`AGENTS.md` already warns that a PVC which is not the CNPG database has no backup. It does not yet
warn about the harder half: **oCIS state is two stores and restoring one without the other is not
a partial restore, it is corruption.** The metadata tree on `ocis-data` names blobs by content hash
in the `ocis-blobs` bucket. Restore the tree and lose the blobs and every file opens as a missing
object while the UI looks entirely healthy — the same "looks fine, is not" failure mode this repo
keeps meeting.

So with the blob mirror ruled out on capacity grounds, **`ocis-data` must not be backed up either.** A one-half backup
is not half a backup; it is a false positive that will pass every check `restic` can run and fail
the only check that matters. Excluding it is the honest option and it is recorded here in plain
words rather than left as an implication:

> **As of 2026-10-22, files uploaded to `files.titan.arrieta.eu` have no backup of any kind.** The
> bucket is not copied and the metadata tree is deliberately not copied either. The single
> remaining safety net is that casa's MinIO is a separate box from titan, which protects against
> titan dying and against nothing else — not deletion, not corruption, not a bad oCIS upgrade, not
> a MinIO failure.

### The path back in, when there is capacity

The ordering argument is worth keeping, because it is the cheap way in and it needs no quiesce —
which matters here, since the binding constraint is bytes rather than downtime, and the ordering
trick costs roughly one copy of the blob store rather than a quiesce plus a copy.
decomposedfs blobs are **content-addressed and append-only in practice**: nothing rewrites an
existing blob, and objects are removed only by trash-bin and project purge after a retention
window. Therefore

> **A bucket snapshot taken after a metadata snapshot is a superset of what that metadata
> references.** Back up the PVC first, then the bucket, in the same window, and never let the
> bucket backup delete objects.

The moment the bucket backup mirrors deletions, the superset property dies and a restore can
reference a blob that was removed from the backup too.

Honest limits of that argument, stated rather than glossed:

- It relies on blobs never being rewritten in place. That is what content-addressing means, but it
  is a claim about oCIS's implementation, not a guarantee in its docs. A future version adding
  server-side re-encryption or blob compaction would break it silently.
- Trash purge *does* delete blobs eventually. A restore to an old metadata tree may reference blobs
  that legitimately no longer exist. Mitigation is retention ordering: keep bucket backups longer
  than PVC backups, so the window where a restored tree can reference a purged blob is bounded by
  PVC retention, not bucket retention.
- There is no quiesce, so the metadata tree is copied live — the §6 SQLite-shaped risk, one layer up.

The alternative that removes all three caveats is a real quiesce: scale `ocis` to zero, snapshot the
PVC, mirror the bucket, scale back. A few minutes of file-service downtime nightly, and the pair is
consistent by construction. Either way it needs the storage capacity that does not currently exist,
which is why both are deferred rather than rejected.

## 5. Scheduling

One job per volume, staggered, each running `restic backup` only. Retention and integrity are
centralised in one housekeeping job (`forget --keep-daily 7 --keep-weekly 5 --keep-monthly 3`, then
a single `prune`) and one weekly integrity job (`check --read-data-subset=2%`), for the reason
techdelivery records: `prune` takes an exclusive repository lock and full-scans the S3 backend, so
running it after every nightly job is nine expensive prunes a day with lock contention.

**Unverified and load-bearing:** techdelivery had to move its whole block out of 03:06–07:10 UTC
because the VPS loses outbound connectivity to the LAN in that window, reproduced over four
consecutive nights. titan is a different OVH instance and there is no measurement of an equivalent
blackout here. Do not assume the absence of one. The first week of schedules should be treated as
provisional until `restic check` and the job completion metrics say otherwise, and the schedules
should sit clear of 03:00–08:00 UTC anyway, because if the cause is shared (OVH egress, the mesh,
the home-side VIP) the most likely place for titan to hit it is the same window.

## 6. Security context, and the `fsGroup` trap

Backup pods mount the source volume `readOnly: true` and run as root with `DAC_OVERRIDE`, because
titan's volumes have heterogeneous owning uids and the obvious fix is a trap: setting `fsGroup`
makes kubelet recursively chgrp a **running workload's** data directory, which can break live pods
mid-backup. So: no `fsGroup`, `capabilities.drop: ["ALL"]` plus `DAC_OVERRIDE`,
`allowPrivilegeEscalation: false`, `seccompProfile: RuntimeDefault`,
`automountServiceAccountToken: false` on an SA with no RBAC.

Measured 2026-10-22: no titan namespace carries a PSA `enforce` label, so this is permitted.
`coder-workspaces` and `observability` carry `pod-security.kubernetes.io/warn: restricted`, which
means these pods will generate audit warnings there. That is noise, not a block — but it is worth
knowing before someone reads a warning as a failure.

`ReadWriteOnce` is not an obstacle: RWO restricts a volume to one *node*, not one pod, and this is
single-node k3s, so the backup pod mounts alongside the running app.

**SQLite-shaped risk, inherited not new.** Any SQLite-backed volume copied live can capture a
mid-transaction state. WAL mode plus copying `db` + `-wal` + `-shm` together is usually recoverable
but is not a guaranteed consistent snapshot. On restore, `PRAGMA integrity_check` before trusting
anything. The upgrade is an initContainer running `sqlite3 <db> ".backup <staged>"`, which needs
exact per-app db paths — deferred, and named so it is not mistaken for done.

## 7. Remaining decisions

1. **Bucket and scoped key on casa MinIO.** A new bucket (proposed `titan-pv-backups`) and an
   access key limited to it — not root credentials. The repo needs roughly 20–40Gi for ~51Gi of
   source after dedup, compression and 7d/5w/3m retention, which is a different order of magnitude
   from mirroring the blob store and is what makes this feasible where the mirror is not. This
   cannot be done from this repo or this identity; it is a casa-side action. Note the trap
   techdelivery records: a nonexistent bucket returns `AccessDenied`, not `NoSuchBucket`, so a
   typo'd bucket name is indistinguishable from a permissions failure until you list what the key
   can see.
2. **Is the 40Gi coder workspace home worth nightly backup?** It is the bulk of the volume and the
   least obviously precious. It decides whether this is an ~11Gi nightly job or a ~51Gi one, which
   matters more than usual given capacity is the binding constraint.
3. **The two unbound 40Gi coder PVs** — delete or back up.

## 8. Out of scope, deliberately

- **Alerting lives in k8s-casa, not here.** `TechdeliveryBackupVolumeStale` and its siblings live in
  `k8s-casa/apply/50-apps/monitoring/techdelivery-backup-alerts.yaml` because casa owns the
  Prometheus that consumes titan's metrics (`docs/titan-metrics-scrape.md`). Titan-side equivalents
  belong beside them. A backup system nobody watches is a backup system that fails silently.
- **MinIO itself is a single point of failure for the backups.** The bucket holding oCIS blobs and
  the bucket holding the backups of everything are on the same MinIO instance. Versioning or a
  second copy is a separate decision with a real cost.
- **Restore drills.** Not done until done. `AGENTS.md` is right that a written backup proves
  nothing; the CNPG work is trusted because a scratch restore and a PITR run were actually
  performed. The restic side gets no more trust than that until the same is true of it.
- **The oCIS blob bucket.** Out of scope by the capacity decision, and §4 records what that costs.
  It should come back as its own spec when there is capacity, not as a bolt-on to this one.
