# PV restore drill — `tools/backup-restore-drill.sh`

Issue: [#101](https://github.com/javierarrieta/k8s-titan/issues/101). Spec:
[`2026-10-22-titan-restic-pv-backups-design.md`](superpowers/specs/2026-10-22-titan-restic-pv-backups-design.md)
§10, which is the list of what had never been proven. This file and the script are the
attempt at the first item on that list: **no restic backup on titan had ever been
restored.**

The Postgres side is different and better covered — a scratch-cluster restore and a
point-in-time recovery have both been drilled and are recorded in
[`authentik-runbook.md`](authentik-runbook.md). Nothing here changes that. This is the
file-copy half.

## Why a drill and not a code review

Every nightly backup job on titan reports success. None of that would change if the
repository were unreadable, the repository password had been rotated in one place and not
another, or the tags a restore needs were not the tags the backup wrote. `restic check`
in `apply/70-backup/housekeeping.yaml` proves the repository's internal structure is
sound; it does not prove a `restore` produces a usable tree, and it has itself never been
exercised against a restore either.

A backup that has only ever been observed succeeding is a hypothesis. The script makes it
falsifiable.

## Access — this is operator-run, and that is not a preference

The script needs a context that can create Jobs and PVCs. The read-only `k8s-reader`
identity cannot, measured 2026-11-03 rather than assumed:

```
kubectl --context titan auth can-i create pod                   -> no
                                       create persistentvolumeclaim -> no
                                       create job                   -> no
                                       get cronjob                  -> yes
```

So run it with an admin context:

```sh
tools/backup-restore-drill.sh probe   --context <admin-ctx>
tools/backup-restore-drill.sh restore --context <admin-ctx>
```

`probe` is read-only against the cluster and creates nothing that survives: it runs one
Job that lists the snapshots for the target tag and prints the latest snapshot id. Do it
first — it answers "is the repository readable with these credentials at all" before
anything allocates storage.

Default target is `mealie/mealie-data`, the smallest opted-in volume (5Gi) with real user
content. The four volumes in scope are `apps/investing-agent-pv-claim`,
`mealie/mealie-data`, `open-webui/open-webui-data` and `sure/sure-storage`; ask for
another with `--namespace` and `--pvc`.

## What a green run actually establishes

The restore Job prints one machine-readable line:

```
DRILL_RESULT target=mealie-data snapshot=2f3a1b9c files_expected=412 files_restored=412 \
  bytes_expected=184320981 bytes_restored=184320981 paths_match=yes \
  content_samples=5/5 match=yes
```

Three independent checks have to agree, and each one catches a different failure:

| check | what it rules out |
|---|---|
| path list from `restic ls --json` == path list on disk | a restore that landed somewhere else, a truncated tree, a filtered subset |
| total bytes from the snapshot == total bytes on disk | silently zero-length files, pack corruption that `ls` cannot see |
| `sha256` of up to 5 files, computed from `restic cat` **and** from the restored file | the whole tree being structurally right and byte-wrong |

And structurally, the Job **never mounts the source PVC** — only the scratch PVC. That is
the design decision that makes the result mean something: a restore that could read the
live volume would pass whether or not the repository worked.

## The traps in it, all of them already paid for

- **The path prefix — and the assumption about it was wrong.** The natural guess is that
  `restic backup /volume` strips the leading slash and stores `volume/...`. The live
  `ls --json` evidence says otherwise: `"paths":["/volume"]` and
  `"path":"/volume/.secret"`, **slash intact**. Comparing those against `find /restore`
  output, which has no leading slash, would report `paths_match=no` on a perfectly good
  restore — a false failure, the worst kind, because it teaches you to distrust the drill.
  So both sides are normalised by stripping a leading `/`, and `restic dump` is offered the
  stored form first and the stripped form second, since which one restic wants is exactly the
  sort of thing that has already changed once. `restic restore --target /restore` still
  produces `/restore/volume/...`, which the `/restore/volume` existence guard checks.
  Worth stating plainly because the wrong version of this claim is the one a future reader is
  most likely to re-guess — including the author of this script.
- **The in-pod scripts are single-quoted bash strings in the outer script.** An apostrophe in
  a comment *inside* them terminates the string and the outer script dies with
  `syntax error near unexpected token 'done'` — which reads like a shell-logic bug and is
  really a quoting bug three hundred characters earlier. Write around it.
- **A restore needs more privilege than a backup, and the set is discovered from the kernel's
  refusals.** The nightly backup jobs run root with `capabilities: drop [ALL], add
  [DAC_OVERRIDE]` — exactly right for reading a heterogeneous-uid volume, exactly wrong for
  writing one back. Two live runs, two refusals:
  1. `lchown /restore/volume/.secret: operation not permitted` — restoring mealie's files to
     uid 911 needs `CAP_CHOWN`.
  2. after granting it, `failed to restore timestamp of "…": operation not permitted` —
     `utimensat` to an arbitrary time needs ownership or `CAP_FOWNER`, and restic had just
     chowned those files to uid 911, so root without `FOWNER` was refused on its own output.

  Both runs restored **12.285 MiB / 12.285 MiB — every byte** — and then exited fatal, because
  restic treats metadata failures as errors. The restore container therefore carries the
  standard restore-as-root set: `CHOWN`, `FOWNER`, `FSETID`, `SETUID`, `SETGID`,
  `DAC_OVERRIDE`, each justified in a comment rather than cargo-culted. All six are in the Pod
  Security `baseline` allowed list. The backup container still carries only `DAC_OVERRIDE`.
  **That asymmetry is the finding**, and nothing in the backup manifests hints at it — a real
  disaster would have discovered it at the worst possible moment. That is the entire argument
  for drilling.
- **`--last` is not a count, and using it silently empties the result.** The second live
  probe printed `Flag --last has been deprecated, use --latest 1` followed by
  `Ignoring "1": no matching ID found for prefix "1"` and `Ignoring "filters": explicit
  snapshot ids are given`, then an empty `LATEST_SNAPSHOT`. At `v0.19.1` the flag is
  `f.BoolVar(&opts.last, "last", false, ...)`, so `--last 1` is the boolean plus a positional
  snapshot id of `1`; the positional wins and the tag filter is discarded. This is precisely
  the flag the backup spec already warns about — techdelivery once let
  `restic snapshots --last 1` misparse in 0.19.x and every tag-based restore claimed no
  snapshot existed. The script now uses **no count flag**: the short id comes off the
  human-readable table (last row = newest, restic sorts ascending), with the JSON
  `"short_id"` as fallback. Both paths were tested against the real probe output before
  shipping.
- **The pinned restic is 0.19.1** (`restic 0.19.1 compiled with go1.26.4`, reported by the
  probe). The JSON key claims above were checked against the `v0.19.1` tag, not `master`.
- **The JSON key names, and `dump` not `cat`.** The first live probe printed an empty
  snapshot id, and reading restic's source instead of guessing again found three wrong
  assumptions at once:
  | assumed | actual (restic `cmd/restic/cmd_snapshots.go`, `cmd_ls.go`, `cmd_dump.go`) |
  |---|---|
  | `snapshots --json` has `"snapshot":"…"` | the keys are `"id"` (full 64 hex) and `"short_id"`; there is no `snapshot` key |
  | `ls --json` marks entries with `"structure-type":"file"` | modern restic uses `"type":"file"` (the script accepts both) |
  | file content comes from `restic cat <snap> <path>` | `restic cat` is for repository internals and rejects a file path; the command is **`restic dump <snapshotID> <file>`** |
  Both JSON streams are compact, one object per line (`json.Encoder.Encode`), which is what
  makes the `tr`/`sed` extraction legal under busybox at all. `probe` now dumps the first
  three `ls --json` records into its own log, so if the shape changes again the evidence is
  in the log rather than a silent empty file list.
- **`for p in $(…)` would have sampled the wrong files.** A filename containing a space
  word-splits, so the sample loop reads from a file with `while IFS= read -r` — the same
  reason `runner.sh` redirects from a file instead of piping into a loop.
- **`local-path`, not `local-path-retain`, for the scratch PVC.**
- **`local-path`, not `local-path-retain`, for the scratch PVC.** Retain leaves a
  `Released` PV behind when the PVC is deleted. titan already carries five of those from
  earlier provisioning churn (#114). A drill that adds litter is a drill people stop
  running.
- **No `backup.titan.arrieta.eu/class` annotation on the scratch PVC.** That annotation is
  the opt-in the discovery CronJob selects on. Annotate a scratch volume and a drill
  artifact becomes production backup data, and `make backup-coverage` would count it.
- **The restic image digest is pinned to the same value as `runner.yaml`.** A drill that
  quietly used a newer restic than production is a drill of a different code path. The
  spec records that techdelivery's restore image once let `restic snapshots --last 1`
  misparse in 0.19.x, which made every tag-based restore claim no snapshot existed — the
  digest is the guard against reliving that.
- **busybox `ash`, not bash.** The in-pod scripts run under the restic image's `/bin/sh`.
  No bashisms, no `jq` — the snapshot id is pulled out with `tr`/`sed`, the same way
  `runner.sh` avoids `jq` for the same reason.
- **Reuse of `backup-job` ServiceAccount and `backup-preflight` ConfigMap.** Both are
  already mirrored into the participating namespaces, so the drill inherits exactly the
  rights the nightly path has, and `rbac.yaml` stays the single place that governs them.
  A drill with its own fat ServiceAccount would test a permission set production does not
  have.

## What a green run does NOT prove — read this before writing "backups verified" anywhere

- **Not application consistency.** A file copy of a live database can restore corrupt;
  that is why `databases/postgres-1` is excluded from restic entirely and why CNPG owns
  that path. Mealie's SQLite and open-webui's state are the same class of risk in
  miniature: this drill restores a *cold* snapshot into a scratch volume, which is the
  safe case. It does not prove that restoring while the app is writing is safe, because it
  isn't.
- **Not that the app starts against the restored volume.** The drill stops at bytes. The
  next rung — mount the restored PVC at a scratch instance of the workload and see it
  come up — is a bigger, noisier drill and is not what this script does.
- **Not the other three volumes.** One volume proves the mechanism (repository,
  credentials, tags, restic version, restore path). It does not prove that
  `open-webui-data`'s snapshot is intact. Run it per volume if you want per-volume
  claims; the script takes `--namespace`/`--pvc` for exactly that.
- **Not that a failure would be noticed.** Nothing alerts on a failed backup job — that is
  the other half of #101, and the same shape of gap is #231 for CNPG objects. A drill you
  ran once and an alert that would have caught the problem are different things.
- **Not that the restore is fast enough to be useful.** No RTO has been measured here.
  The 10Gi volumes over the mesh to casa's MinIO are the numbers that would matter and
  they are not recorded anywhere yet.

## What the first live probe proved (2026-11-03)

`tools/backup-restore-drill.sh probe --context titan` against `mealie/mealie-data`:

- `preflight: probing s3.l.arrieta.eu with 'restic cat config'` → **endpoint answered,
  repository exists**. The credentials mirrored into `mealie` as `backup-minio-secrets`
  open the repository. That alone was unproven before this.
- **The tag is the PVC name and it matches.** 8 snapshots under tag `mealie-data`, latest
  `0c8e1f99` at 2026-11-02 20:30 UTC, 12.285 MiB, sizes climbing ~1.1 MiB/day. So the
  nightly writer and a tag-based reader agree on the tag — the failure mode where a renamed
  PVC leaves snapshots under the old name did not happen here.
- The nightly cadence is intact: one snapshot per day at 20:30 UTC, matching the `30 20 * * *`
  discovery schedule.
- And it found the three format bugs above, which is what the stage was for.

A second probe on the fixed script (same day) reported `restic 0.19.1 compiled with go1.26.4`,
confirmed the snapshot list again, and then failed on `--last 1` — the bug described in the
traps section. **Two probes, two real bugs, zero cluster writes.** That is the argument for
making the read-only stage separate from the restore stage.

**Still unproven after this probe:** that a `restore` works. `probe` reads the repository and
lists snapshots; it does not write a tree. That is the `restore` stage.

## The first live restore attempts (2026-11-03)

Two runs of `restore --context titan` against `mealie/mealie-data`. Both failed, and the
failures are the most useful thing in this file.

Run 1 ended with `lchown …: operation not permitted` × 21. Run 2, with `CAP_CHOWN` granted,
ended with `failed to restore timestamp of "…": operation not permitted` × 21. Both ended:

```
Summary: Restored 10 / 22 files/dirs (12.285 MiB / 12.285 MiB) in 0:00
Fatal: There were 21 errors
```

Read that summary carefully, because it contains both the good news and the bad:

- **12.285 MiB / 12.285 MiB — every byte restored, twice.** The repository, the mirrored
  credentials, the tag lookup, the snapshot id, the `--target` layout and the `/volume` prefix
  are all proven against the real thing, not against a reading of restic's source.
- **Every error was metadata, none was content.** Ownership, then timestamps.
- **The verification block never ran**, because restic exited non-zero first. The byte-level
  `sha256` comparison — the strongest of the three checks — has still never executed against
  real data. Bytes reaching disk is not the same as the drill having checked them.

Scratch PVC and Jobs were cleaned up on both failure paths, as designed.

## If it fails

| symptom | first thing to look at |
|---|---|
| `ABORT: preflight failed` | the mesh — `preflight.sh` probes the S3 endpoint only. `ping 192.168.133.x`, then casa's MinIO. |
| `LATEST_SNAPSHOT <none>` | both extraction paths failed. `probe` dumps the raw `ls --json` head and the snapshot table — read those. If a count flag has crept back in, see the `--last` bullet above. |
| `ABORT: no snapshot found for tag <pvc>` | the tag is the PVC name, set in `runner.sh`. A renamed PVC has old snapshots under the old tag and none under the new one. |
| `paths_match=no` with plausible counts | check the `volume/` prefix assumption before believing anything else |
| `content_samples=k/n` | the repository is readable and the tree is complete but bytes differ — stop and treat the repository as suspect, do not re-run |
| `lchown …: operation not permitted` | restore container lacks `CAP_CHOWN`. Content is fine; ownership is not. |
| `failed to restore timestamp of …: operation not permitted` | lacks `CAP_FOWNER` — `utimensat` on a file whose owner is not us. See the capability bullet. |
| `WARNING: /restore/volume is absent` | the stored paths are not under `volume/` — the prefix assumption is wrong for this volume, do not trust the counts below it |
| Job stuck Pending | the scratch PVC cannot bind — `kubectl describe pvc <pvc>-drill`, usually capacity on titan's local path |

`cleanup` removes the scratch PVC and any drill Jobs in the namespace:

```sh
tools/backup-restore-drill.sh cleanup --context <admin-ctx> --namespace mealie --pvc mealie-data
```

`restore --keep` leaves both in place for inspection. Do not leave them: the scratch PVC
holds a full copy of production data under a name that says it is safe to delete.

## How the script itself was tested

Two live probes found five bugs, so the verification logic was eventually run locally
against a fake `restic` before the next attempt shipped — the extracted in-pod script,
executed with a stub `restic` emulating 0.19.1's compact one-object-per-line `ls --json`,
**including the leading-slash paths the live evidence showed.** Running the old body against
that stub is what reproduced `paths_match=no` before any cluster was touched.

| case | result |
|---|---|
| clean restore of a tree containing `two words.txt`, stub paths `/volume/...` | `files_expected=3 files_restored=3 bytes_expected=3035 bytes_restored=3035 paths_match=yes content_samples=3/3 match=yes`, exit 0 |
| one byte appended to one restored file | `bytes_restored=3036`, `content_samples=2/3`, `MISMATCH /volume/data/one.txt repo=… disk=…`, `match=no`, **exit 1** |

The second row is the one that matters: **a check that can only pass is worthless**, so the
deliberate-corruption case is the proof the gate is live. The filename with a space is the
case the old `for p in $(…)` loop would have silently mis-sampled.

What this does **not** cover: real restic behaviour, real S3, real `local-path`
provisioning, and the `restic restore` file layout itself — the fake `cp -a`s the tree. Only
a live run covers those, which is what `restore --context titan` is for.

## Recorded runs

Same rule as the Postgres drills — a drill is a dated artifact, not a claim. Record the
`DRILL_RESULT` line, the snapshot id, the volume and the date, and say what was **not**
covered.

### 2026-11-03 — `mealie/mealie-data`, snapshot `0c8e1f99` — **PASS**

```
Summary: Restored 22 files/dirs (12.285 MiB) in 0:00
DRILL_RESULT target=mealie-data snapshot=0c8e1f99 files_expected=9 files_restored=9
  bytes_expected=12881822 bytes_restored=12881822 paths_match=yes
  content_samples=5/5 match=yes
```

Snapshot `0c8e1f99` is the 2026-11-02 20:30 UTC nightly backup. Restored into
`mealie/mealie-data-drill` (`local-path`, 5Gi), verified, cleaned up. Elapsed: seconds.

Three things worth pointing at in that line:

- **`bytes_expected=12881822` is the snapshot's own `total_bytes_processed`**, reported
  independently by `restic ls` on the other side of the restore. Two different restic
  commands agreeing on the byte count is stronger than one command agreeing with itself.
- **`content_samples=5/5`** means five files were read out of the repository with
  `restic dump` and off the restored volume with `sha256sum`, and matched byte for byte.
  This is the check the two failed runs never reached.
- **`files_expected=9` against `Restored 22 files/dirs`** is not a contradiction: 22 counts
  directories too, and the comparison is regular-files to regular-files on both sides.

**What this run does not cover**, restated so nobody has to go looking: the other three
opted-in volumes; application consistency (this is a cold snapshot into a scratch volume, not
a restore under load); whether an app starts against a restored volume; whether a failed
backup would be noticed, since nothing alerts on it; and any RTO — no timing has been
measured for the 10Gi volumes.

**What it cost to get here:** five bugs, all found by the drill rather than by production.
`snapshots --json` key names, `ls --json` key names, `restic dump` rather than `restic cat`,
`--last` being a boolean rather than a count, the leading-slash path assumption, and two
missing capabilities. Every one of them would have been a failed restore during a real
incident.

### Future runs

Run it per volume if per-volume claims are wanted:

```sh
for t in "apps investing-agent-pv-claim" "open-webui open-webui-data" "sure sure-storage"; do
  set -- $t
  tools/backup-restore-drill.sh restore --context <admin-ctx> --namespace "$1" --pvc "$2"
done
```

Paste the `DRILL_RESULT` line back into this file with the date. A run that failed belongs
here too — that is the version people need.
