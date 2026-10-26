# titan restic PV backups — design

Status: **implemented in this PR, not yet applied to the cluster.** The first reconcile is the
first test, and §9 records what has and has not been proven.

Supersedes its own first draft (2026-10-22), which was design-only and had three things wrong in
it: it named the stage `30-backup`, which `apply/30-databases` already occupies; it described
`files/ocis-data`, which OpenCloud replaced on 2026-10-23 (#143); and it enumerated volumes in
static CronJobs, which cannot cover a coder workspace volume at all. §7 is where those changed
and why.

The deferred trigger. `2026-10-03-k8s-titan-flux-bootstrap-design.md` §13b deferred the generic
PV stream "until a workload with data that is not that database arrives", and recorded that the
override was compensated only because CNPG carries its own backup path. That trigger fired a
third time and the compensation no longer covers it: file stores, workspace homes, uploads and
dashboard state all live on PVCs that CNPG's base backups do not touch. The deferral is spent.

The mechanism is not invented here. It is a port of `k8s-techdelivery/apply/30-backup/`, which
has been running on the OVH VPS, has a written restore procedure, has alerts that were induced
and observed to fire, and carries the accumulated scars — the nightly connectivity blackout, the
`AccessDenied`-not-`NoSuchBucket` trap, the `fsGroup` trap, the prune-eating-a-volume incident
(repo Issue #13), the busybox `timeout` exit code that made a preflight check report the opposite
of what it found (#148), and the `restic snapshots`-means-no-repo conflation (#149). Read that
README before this one; several choices here look arbitrary without it.

## 1. Direction, and why the port is close to a copy

titan is an OVH single-node k3s box backing up to casa's MinIO over the WireGuard mesh. That is
the same direction as techdelivery → casa MinIO, so the failure domains are already independent
(OVH vs home LAN) and the transport is already proven.

Measured 2026-10-26 from inside pod network — this workspace is a coder workspace pod on titan,
so its resolver and routes are the ones a backup pod gets:

| probe | result |
|---|---|
| `s3.l.arrieta.eu` resolution from a pod | resolves |
| TCP `:443` | connects |
| TLS | verifies against the system CA store, no custom CA needed |
| `HEAD /titan-pv-backups` | **200**, `x-amz-bucket-region: eu-west-1`, `Server: MinIO` |

The first draft argued for `http://192.168.0.6:9000` on the grounds that `s3.l.arrieta.eu` is
only pinned to `192.168.0.42` in the *host's* `/etc/hosts` (`nixos-configurations
hosts/titan/configuration.nix:483`) and a pod gets kubelet's hosts file instead. That reasoning
was sound and the conclusion was wrong: the name resolves from a pod anyway, over the mesh, and
using it keeps this stage identical in shape to techdelivery's. The endpoint is
`s3:s3.l.arrieta.eu/titan-pv-backups`.

Two things differ from techdelivery and both matter:

- titan's Postgres is CNPG, not Databasus. CNPG already ships base backups and continuous WAL to
  S3, drilled for both full restore and PITR (`docs/authentik-runbook.md` §2). So the database PV
  is excluded for the same *reason* techdelivery excludes it, under a different owner.
- titan has a workload whose persistent state is split across two stores that must be restored
  together. That is §4.

## 2. Coverage, and the annotation that decides it

**A PVC opts in with `backup.titan.arrieta.eu/class: daily`. No annotation, no backup.** That is
the whole scope mechanism; §7a explains why it replaced static per-volume CronJobs.

Live inventory measured 2026-10-26 (`kubectl get pvc -A`, `kubectl get pv`):

| PVC | Size | StorageClass | class | Why |
|---|---|---|---|---|
| `apps/investing-agent-pv-claim` | 10Gi | `local-path-retain` | `daily` | agent state; also the volume `docs/investing-agent-pv-edits` records hand-edits inside, which no gate can see |
| `apps/tesla-grafana` | 1Gi | `local-path` | `daily` | dashboards and provisioning not in git |
| `coder-workspaces/coder-*-home` | 40Gi | `local-path-retain` | **no — by decision, §7c** | operator's rule: a workspace should be reproducible from its image and from git, so a home that needs backing up is a workspace doing something it should not |
| `mealie/mealie-data` | 5Gi | `local-path-retain` | `daily` | recipe uploads; the relational half is in CNPG |
| `observability/grafana-data` | 1Gi | `local-path-retain` | `daily` | same as tesla's, different namespace |
| `open-webui/open-webui-data` | 10Gi | `local-path-retain` | `daily` | uploads and local index |
| `sure/sure-storage` | 5Gi | `local-path-retain` | `daily` | Active Storage uploads |
| `files/opencloud-data` | 5Gi | `local-path-retain` | **none — see §4** | half a backup is worse than none |
| `databases/postgres-1` | 10Gi | `local-path` | **no** | CNPG owns it. A file-level copy of a live Postgres datadir can restore corrupt, and CNPG's own path is drilled. |

~32Gi annotated and in effect. coder's 40Gi home is excluded by decision (§7c), which is the
difference between a 32Gi nightly set and a 72Gi one. The first draft's "~51Gi across 4 PVCs" was
a different cluster: three of those volumes did not exist yet.

`kubectl get pvc -A -L backup.titan.arrieta.eu/class` is the answer to "what is backed up", asked
of the cluster rather than of this file.

### Five Released PVs, still nobody's

`coder-home-recovered` (40Gi), `pvc-2a10168c-…` (40Gi), `pvc-3694c681-…`, `pvc-80e2343d-…` and
`pvc-86aae016-…` (3×5Gi, two `opencloud-data` generations and one `ocis-data`). All `Released`:
the claim is gone, the bytes are on disk, no PVC points at them and no process will ever delete
them. The first draft named two; the OpenCloud cutover added three more by recreating the same
PVC name. They are named here so they are not discovered later. If they are stale recovery
staging they should be deleted, not backed up — and note that a restic backup of a Released PV is
not even expressible here, because a job mounts a PVC and these have none. Two of the five are
coder homes, so under §7c nobody will ever back them up or delete them; they are 80Gi of
unaddressable-by-design bytes sitting on the only disk this cluster has.

## 3. Stage shape

New top-level stage **`apply/70-backup/`** with its own `kustomization.yaml`, its own
`apply/00-bootstrap/stage-backup.yaml`, and an entry in `00-bootstrap/kustomization.yaml` — the
one-directory-one-Kustomization-one-failure-domain rule from `AGENTS.md`.

**Not `30-backup`.** The first draft proposed that number and `apply/30-databases` already owns
it. One numbered directory is one stage, so the proposal would have put two stages in one slot.
The number is reading order only — `dependsOn` is what orders reconciles — but a duplicate number
is an hour someone else spends.

`prune: false` **and** `deletionPolicy: Orphan`, both required, for the reason techdelivery
documents: `Orphan` governs only deletion of the Kustomization object, while `prune: true` still
deletes individual manifests removed from git. The property wanted is "a GitOps accident cannot
delete the thing that guards against the accident", which needs both. Consequence accepted in
advance: retiring a backup job deliberately means `kubectl delete cronjob`, not a commit, and
nothing in CI will tell you that a job removed from git is still running nightly. Every other
stage here uses `prune: true`; that asymmetry is the point.

**One copy of each shared object, mirrored by Reflector.** A backup job must run in the namespace
that owns its PVC — a pod cannot mount a volume from another namespace — so everything the job
needs is namespace-local. That would have meant six copies of the credential and six copies of a
150-line script. Reflector mirrors both: `backup-minio-secrets` (declared once in `apps`, like
every Secret here, and sops-encrypted like every Secret here) and `backup-preflight`. What it
cannot mirror is RBAC, so `apply/70-backup/rbac.yaml` is six namespaces × SA + Role +
RoleBinding, and that file is the one place the fan-out is hand-written. See §7b for the
convention this reverses.

restic and kubectl pinned **by digest, never a floating tag**:
`restic/restic@sha256:136600b6ff6843d61d355f7f71f460a166429f35de6fd11b568fece3c9a4d510` (0.19.1,
matching the version techdelivery's scars were learned against) and
`alpine/k8s@sha256:18bc02c1e0df04451f4f9194eb7b7341c1165da5495459b52f85f72fb9545032` (1.35.0,
against a `v1.35.8+k3s1` API server). The rule and its reason are techdelivery's: its restore
image's CI once let `restic snapshots --last 1` silently misparse in 0.19.x, which made every
tag-based restore exit 3 claiming no snapshot existed.

## 4. OpenCloud is out of scope, and that means files have no backup

`AGENTS.md` already warns that a PVC which is not the CNPG database has no backup. It does not
warn about the harder half: **OpenCloud's state is two stores and restoring one without the other
is not a partial restore, it is corruption.** The metadata tree on `files/opencloud-data` names
blobs by content hash in casa's `opencloud-blobs` bucket. Restore the tree and lose the blobs and
every file opens as a missing object while the UI looks entirely healthy.

So with the blob mirror ruled out on capacity grounds, **`opencloud-data` must not be backed up
either.** A one-half backup is not half a backup; it is a false positive that will pass every
check restic can run and fail the only check that matters. Excluding it is the honest option, and
it is now a property of the cluster rather than a comment: that PVC carries no
`backup.titan.arrieta.eu/class`, and `apply/50-apps/opencloud/opencloud.yaml` says so where the
missing annotation would have gone.

> **As of 2026-10-26, files uploaded to `files.titan.arrieta.eu` have no backup of any kind.**
> The bucket is not copied and the metadata tree is deliberately not copied either. The single
> remaining safety net is that casa's MinIO is a separate box from titan, which protects against
> titan dying and against nothing else — not deletion, not corruption, not a bad OpenCloud
> upgrade, not a MinIO failure.

### The path back in, when there is capacity

The ordering argument is worth keeping, because it is the cheap way in and it needs no quiesce.
decomposedfs blobs are **content-addressed and append-only in practice**: nothing rewrites an
existing blob, and objects are removed only by trash-bin and project purge after a retention
window. Therefore

> **A bucket snapshot taken after a metadata snapshot is a superset of what that metadata
> references.** Back up the PVC first, then the bucket, in the same window, and never let the
> bucket backup delete objects.

The moment the bucket backup mirrors deletions, the superset property dies and a restore can
reference a blob that was removed from the backup too.

Honest limits, stated rather than glossed:

- It relies on blobs never being rewritten in place. That is what content-addressing means, but it
  is a claim about OpenCloud's implementation, not a guarantee in its docs. Server-side
  re-encryption or blob compaction would break it silently.
- Trash purge *does* delete blobs eventually. A restore to an old metadata tree may reference
  blobs that legitimately no longer exist. Mitigation is retention ordering: keep bucket backups
  longer than PVC backups.
- There is no quiesce, so the metadata tree is copied live — the §6 SQLite-shaped risk, one layer
  up.

The alternative that removes all three caveats is a real quiesce: scale `opencloud` to zero,
snapshot the PVC, mirror the bucket, scale back. Either way it needs capacity that does not exist,
which is why both are deferred rather than rejected.

## 5. Scheduling

One runner per namespace, staggered 18:30–21:00 UTC, each creating one `restic backup` job per
annotated volume. Retention and integrity are centralised in one housekeeping job
(`forget --keep-daily 7 --keep-weekly 5 --keep-monthly 3`, then a single `prune`, 09:00) and one
weekly integrity job (`check --read-data-subset=2%`, Sunday 10:00), for the reason techdelivery
records: `prune` takes an exclusive repository lock and full-scans the S3 backend, so running it
after every nightly job is N expensive prunes a day with lock contention.

Child-job deadlines are derived from each volume's size — 15 min per GiB, floor 1h, ceiling 8h —
rather than hand-tuned per volume, because with discovery there is no per-volume manifest to tune.
Measured against the arithmetic: 1Gi→1h, 5Gi→1.25h, 10Gi→2.5h, 40Gi→8h (capped).

With coder out of scope (§7c) the largest volume in the set is 10Gi, whose derived deadline is
2.5h, so the last start (21:00 UTC) finishes by roughly 23:30 with hours of margin before the
window.

**Unverified and load-bearing:** techdelivery had to move its whole block out of 03:06–07:10 UTC
because the VPS loses outbound connectivity to the LAN in that window, reproduced over four
consecutive nights. titan is a different OVH instance and there is no measurement of an
equivalent blackout here. Do not assume the absence of one. Every start is placed so that even
the largest deadline (coder's 8h from 18:30) ends before 03:00, and the first week of these
schedules is provisional until `restic check` and job completion say otherwise.

## 6. Security context, and the `fsGroup` trap

Child backup pods mount the source volume `readOnly: true` and run as root with `DAC_OVERRIDE`,
because titan's volumes have heterogeneous owning uids and the obvious fix is a trap: setting
`fsGroup` makes kubelet recursively chgrp a **running workload's** data directory, which can
break live pods mid-backup. So: no `fsGroup`, `capabilities.drop: ["ALL"]` plus `DAC_OVERRIDE`,
`allowPrivilegeEscalation: false`, `seccompProfile: RuntimeDefault`. The runner pods are the
opposite — uid 65534, no capabilities, no volume mounted — because they only talk to the API.

Measured 2026-10-22 and re-read 2026-10-26: no titan namespace carries a PSA `enforce` label, so
this is permitted. `coder-workspaces` and `observability` carry
`pod-security.kubernetes.io/warn: restricted`, which means the child pods generate audit
warnings there. Noise, not a block — but worth knowing before someone reads a warning as a
failure.

`ReadWriteOnce` is not an obstacle: RWO restricts a volume to one *node*, not one pod, and this is
single-node k3s, so the backup pod mounts alongside the running app.

**SQLite-shaped risk, inherited not new.** Any SQLite-backed volume copied live can capture a
mid-transaction state. WAL mode plus copying `db` + `-wal` + `-shm` together is usually
recoverable but is not a guaranteed consistent snapshot. On restore, `PRAGMA integrity_check`
before trusting anything. The upgrade is an initContainer running `sqlite3 <db> ".backup
<staged>"`, which needs exact per-app db paths — deferred, and named so it is not mistaken for
done.

## 7. Decisions

### a. Discovery, not one CronJob per volume — the annotation is the contract

The first draft's plan was a static CronJob per volume. That is fine for every PVC declared in git
and **impossible for the ones created at runtime**: coder names a workspace volume
`coder-<uuid>-home` and recreates it whenever a workspace is rebuilt. A manifest naming one of
those silently backs up nothing from the day the workspace is recreated, with every gate green —
a CronJob that targets a vanished PVC fails at mount time in a pod nobody looks at, and nothing
in this repo's gate set can see a PVC that is not in git.

So each participating namespace runs one `backup-discovery` CronJob that lists its own PVCs,
keeps the ones carrying the annotation, and creates one child Job per volume. The runner cannot
mount a volume discovered after it started, which is why it creates jobs instead of doing the
work; that is also the only reason this stage needs RBAC while techdelivery's service account is
deliberately empty and says so.

What it costs, honestly:

- **RBAC.** Per namespace: PVC `get,list` and jobs `create,get,list`. Not cluster-wide, no
  `get secrets` — the child references the credential by name through `envFrom`, which kubelet
  resolves, so the runner never reads it. Widening that to secrets would turn a compromised runner
  pod into a credential theft instead of a namespace job-spam problem. No `delete` on jobs, so a
  compromised runner cannot erase the record that a backup ran.
- **A second image** (kubectl) and **~150 lines of shell** that has to get overlap, deadlines and
  name-length limits right.
- **Four things in three files must agree** for an annotated PVC to actually be backed up: the
  annotation, a runner in that namespace, that namespace in the Reflector mirror list on *both*
  mirrored objects, and the namespace's SA/Role/RoleBinding. Every one is a one-line edit
  somewhere else, and every one fails the same way — quietly, at 18:30, in a namespace nobody is
  watching. `secret-refs` cannot see it, because the jobs that consume the mirrored Secret are
  created at runtime and are not in the tree.

**And one honest consequence of §7c.** coder being out removes the strongest argument for
discovery: a coder workspace volume is the only in-scope-shaped volume a static CronJob cannot
name. What is left justifying the runner is weaker but real — a new app opts in with one line on
its own PVC instead of editing this stage, the mirror list and an RBAC file, and if the coder
decision is ever revisited the mechanism is already there. If you would rather have the simpler
shape, the static version is six CronJobs, no RBAC, no runner, and a rule that a workspace
recreation silently drops a volume out of scope; that trade is worth making deliberately rather
than inheriting, and this paragraph exists so it is visible.

That fourth bullet is what `make backup-coverage` (`tools/backup-coverage-check.py`) is for. It
runs on built objects, is keyless so it sits in `check-ci`, refuses to report clean when no PVC is
annotated or no runner exists, and was verified against the shipped tree by mutating it six ways:
delete a runner, drop a namespace from the mirror list, make the two mirror lists disagree,
delete a RoleBinding, typo a class as `daly`, and strip every annotation. Each fails with a
sentence naming the namespace and the consequence.

Its honest limit is the same shape as every other offline gate here: it proves the tree agrees
with itself. It cannot prove the live PVC carries the annotation, that Reflector is healthy, or
that a backup ever ran.

**Class vocabulary.** `daily` is the only class today. An unknown class is rejected by the gate
rather than silently treated as `daily`, because a typo'd class is otherwise a silent wrong
answer. Adding `weekly` or `precious` means a schedule in the runner and a line in
`KNOWN_CLASSES`.

### b. Reflector now carries a credential — a deliberate reversal

`apply/20-infra/reflector/reflector.yaml` says, in its own words, that Reflector "replicates TLS
material across namespaces and nothing else", and that the database credential was authored
instead (bootstrap spec 4 A4) precisely so Reflector would not become a second secret-sync
mechanism by accident. That decision is reversed here, for one credential and one ConfigMap.

The reason is arithmetic, not preference: six namespaces × one credential and a 150-line script
is either six copies in git that can drift, or one copy mirrored. The earlier decision was made
about *two* copies of a password inside one file, where a single edit moves both halves. The same
file also states the thing that makes this reversal survivable rather than reckless: the TLS-only
scope "is a convention, not a boundary" — the chart's ClusterRole already grants `secrets` and
`configmaps` with `["*"]` cluster-wide, so a compromised Reflector already had every Secret in the
cluster and nothing is being newly exposed. What changes is that review, not RBAC, is now
vouching for which objects get mirrored. Both mirror lists are explicit namespace lists, never
"all namespaces", and the gate compares the two lists against each other.

### c. The three open decisions from the first draft

1. **Bucket and scoped key — done.** `titan-pv-backups` on casa's MinIO with
   `docs/titan-pv-backup-policy.json`, attached to a user (not a service account — see
   `docs/opencloud-minio.md` §2). Proven with a signed client, not assumed: `HeadBucket` 200,
   `ListObjectsV2` 200 with `KeyCount: 0`, `?uploads` 200, five `PUT`s 200, `GET` on a missing key
   returns `NoSuchKey` rather than `AccessDenied` (so `GetObject` is granted, which is how you tell
   the two apart), `DELETE` 204, region `eu-west-1`. Not granted: bucket create/delete, policy,
   lifecycle, replication, and anything on any other bucket — so a compromised backup pod cannot
   touch `opencloud-blobs`, `titan-etcd` or the CNPG bucket, and cannot delete the bucket it
   backs up into. **Versioning must stay off**: `prune` deletes pack objects, and with versioning
   every deleted pack survives as a noncurrent version so the bucket never shrinks and retention
   silently stops working.
2. **Is the 40Gi coder home worth nightly bytes?** — **no, decided by the operator on
   2026-10-26: "everything should be in the image or in git."** So `coder-workspaces` has no
   runner, is not in either Reflector mirror list, and has no RBAC here. The consequence is
   written down rather than left implied: **anything a workspace holds that is neither in its
   image nor pushed to git is not recoverable** — uncommitted work, `pip install`ed state,
   databases a person started inside their own home directory, downloaded datasets. That is a
   reasonable rule for a dev box and it is also the rule that will be discovered the first time
   someone loses an afternoon. If it ever needs revisiting, the mechanism is a namespace added to
   two annotations plus an RBAC block, and the annotation on the workspace storage block in
   `coder-templates`. §7a records that this decision also weakens the case for discovery.
3. **The Released PVs** — still open, and now five rather than two (§2). Note the mechanism
   cannot help: a job mounts a PVC and a Released PV has none.

## 8. Out of scope, deliberately

- **Alerting lives in k8s-casa, not here.** `TechdeliveryBackupVolumeStale` and its siblings live
  in `k8s-casa/apply/50-apps/monitoring/techdelivery-backup-alerts.yaml` because casa owns the
  Prometheus that consumes titan's metrics (`docs/titan-metrics-scrape.md`). Titan-side
  equivalents belong beside them. A backup system nobody watches is a backup system that fails
  silently, and **until those alerts exist this stage is unmonitored**: a week of failed backups
  looks exactly like a week of successful ones from where anything is watching.
- **MinIO itself is a single point of failure for the backups.** The bucket holding OpenCloud's
  blobs, the bucket holding the CNPG backups, the etcd snapshot bucket and the bucket holding the
  backups of everything are on one MinIO instance. Versioning or a second copy is a separate
  decision with a real cost.
- **Restore drills.** Not done until done. `AGENTS.md` is right that a written backup proves
  nothing; the CNPG work is trusted because a scratch restore and a PITR run were actually
  performed. The restic side gets no more trust than that until the same is true of it. §9 is the
  procedure and §10 is what has to be observed before anyone says "backed up".
- **The OpenCloud blob bucket.** Out of scope by the capacity decision, and §4 records what that
  costs. It should come back as its own spec when there is capacity, not as a bolt-on.

## 9. Restore procedure

Nothing here has been executed. It is written before the drill so the drill has something to
falsify.

```sh
# 1. find the snapshot
kubectl -n apps exec job/backup-integrity -- restic snapshots --tag open-webui-data
# or from any pod with the credential mounted; RESTIC_* come from backup-minio-secrets

# 2. restore into a scratch PVC, never over a live volume
kubectl -n open-webui restore ...   # or a Job mounting a fresh PVC and `restic restore <snap> -t /volume`

# 3. only after the scratch copy looks right: scale the workload to zero, restore in place, scale up
```

Rules that come from techdelivery's incidents rather than from taste:

- **Never restore over a live volume.** `restic restore` on a mounted, running workload's
  directory is how you turn a restore into an outage.
- **`--last 1` is not a synonym for "the newest".** techdelivery's restore image caught 0.19.x
  misparsing it and reporting no snapshot existed. Name the snapshot ID.
- **SQLite-backed volumes: `PRAGMA integrity_check` before trusting anything** (§6).
- **OpenCloud is not restorable from this stage at all** (§4). If someone restores
  `opencloud-data` from an older snapshot, the tree will reference blobs that may not exist and
  the UI will look fine.
- The stage runs `prune: false` / `deletionPolicy: Orphan`, so **a deleted job is not recovered by
  a revert** — `kubectl delete cronjob` is the only way to retire one, and `git revert` will not
  bring it back either if the manifest is still in git.

## 10. Implementation record — what is proven and what is not

Proven by measurement, 2026-10-26:

| claim | evidence |
|---|---|
| the bucket and key work, read and write | signed-client probes in §7c, including the `NoSuchKey`-vs-`AccessDenied` distinction |
| region is `eu-west-1` | response header, and two prior independent measurements in this fleet (`hosts/titan/vars.nix`, `docs/opencloud-minio.md`) |
| the endpoint is reachable from pod network | resolution, TCP and TLS verified from a coder workspace pod on titan |
| the three scripts are POSIX-shell valid | `sh -n` on each, after removing a `${VAR//}` bashism and a counter lost to a pipe subshell |
| the generated child Job is well-formed | the heredoc rendered with real values and parsed; deadline arithmetic checked at 1Gi/5Gi/10Gi/40Gi/1Ti |
| `make backup-coverage` is not vacuous | six deliberate mutations, each failing with a named namespace and consequence |
| `make check-ci` green | leak-check, kustomize-check, kustomize-listing (105 manifests, 0 unlisted), secrets-placement, release-secrets, secret-refs (42 refs), backup-coverage, crd-check (40 objects), namespace-check (236 objects) |

Not proven, and this is the long list:

- **Nothing has run.** No pod, no snapshot, no restore. The first reconcile is the first test.
- **`make dry-run` ran with an admin context and rejected this stage — and it was right to.**
  Seven objects came back `failed to create typed patch object ... .spec.jobTemplate.spec.template
  .spec.securityContext.allowPrivilegeEscalation: field not declared in schema`. I had put
  `allowPrivilegeEscalation` and `capabilities` in the **pod** securityContext; those are container
  fields, and `PodSecurityContext` does not declare them. Every offline gate was green. The same
  bug was in the child job the runner writes at runtime, where dry-run can never reach it, so the
  fix came with a check in `backup-coverage` that renders the heredoc and validates it — see that
  tool's `POD_SC_ALLOWED`. What is still unproven is everything the API server checks that this
  stage has not yet been asked about on a re-run.
- **The dry-run gate itself was silently skipping three stages.** `scripts/dry-run-check.sh`
  hardcoded `STAGES=(00-bootstrap 10-secrets 20-infra 40-certificates 50-apps)`; `30-databases`,
  `60-tesla` and this stage were never asked, while the run printed `5 stage(s) built, 5 accepted`
  over the subset. It now derives the list from `apply/*/kustomization.yaml`. The honest
  consequence for the record: the CNPG `Cluster`, the `ScheduledBackup` and all of TeslaMate had
  never been dry-run before this PR, and still have not been asked about anything that PR changed.
- **`make check` (full) does run on this machine** — it holds a sops recipient key, and one of the
  five recipients decrypts every Secret in the tree, so `validate` and the agreement gates all
  executed. That is a property of this workspace, not of CI, which correctly has no key.
- The blackout avoidance in §5 is inherited from techdelivery, not measured on titan.
- Whether Reflector actually mirrors both objects is untested; the mirror list is asserted by the
  gate only in the sense that the annotations are present and agree.
- Whether the runner's `kubectl apply` succeeds with its Role in a real namespace is untested;
  the Role grants `create` and the failure mode if it is wrong is a 403 in the runner log.
- coder volumes are excluded by decision, not by omission (§7c) — nothing tests that the
  exclusion is still what the operator wants.
- No alert exists for a missed backup (§8). Until one does, "backed up" is not a claim anyone can
  make from observation.
