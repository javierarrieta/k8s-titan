# titan runbook — Postgres backups, restore drill, authentik

Scope: the shared CloudNativePG `Cluster` in `databases` and the authentik install that
depends on it. Written against operator 1.30.1 / Postgres 18.6 on titan.

**Proven vs pending.** Everything below describes a deployed system: the backup path, the
restore drill, point-in-time recovery, the CloudNativePG operator, the shared `Cluster`, and
authentik itself are all live on titan and were checked rather than assumed, and the first
admin exists (§4), the old S3 backup key has been **deleted from IAM** (§1), and
the restore drill has passed against authentik's own tables (§2, recorded) — after its first
attempt died on a wrong table name and the two bugs that hid that. Sections say which
of their claims were observed and which are reasoning.

**A shell note, because it bites twice here.** The operator's login shell is fish, and several
blocks below use `VAR=value command`, which is bash — fish parses that as a command literally
named `VAR=value`. Prefix with `env` and it works in any shell: `env SEED=0 DELETE=1
./scripts/restore-drill.sh`. The scripts themselves are fine from any shell; they carry a bash
shebang, which is why the rotation is a script rather than a paste-able block.

---

## 1. Backup topology

There are two backup destinations in this design and only one of them exists yet.

| destination | opened by | state |
|---|---|---|
| `s3://k8s-titan-pg-562256260016-eu-west-1-an` — base backups + continuous WAL for the Postgres cluster | `databases/s3-backup-secrets` (`ACCESS_KEY_ID`, `SECRET_ACCESS_KEY`, `AWS_REGION`), IAM user `k8s-titan-pg-backups` | **live and verified** |
| restic CronJobs → MinIO `titan-pvc` — the generic PV stream from the bootstrap spec | `backup-minio-secrets`, a `30-backup` stage | **not implemented.** Bootstrap spec §9 records the override and its compensation |

The second row matters because the first one is what pays for it: the bootstrap design
overrode "no PV without backup" on the promise that the database carries its own backup
path. That promise is discharged by the first row, not by the second.

Layout under the bucket, per cluster name:

```
postgres/base/<backupId>/backup.info
postgres/base/<backupId>/data.tar
postgres/wals/<timeline>/<segment>
postgres/wals/<timeline>/<segment>.<offset>.backup   # barman's history marker
```

`retentionPolicy: 30d` is enforced by `barman-cloud-backup-delete` with the same
credentials. An S3 lifecycle rule is a backstop for noncurrent versions, not retention —
do not let anyone consolidate the two.

Two things that are easy to get wrong and are commented at length in
`apply/30-databases/`: `schedule` needs **six** cron fields (`"0 0 3 * * *"`),
because CNPG pins robfig/cron v1.2.0 where the optional field is day-of-week at the end,
so the familiar five-field form fires hourly; and `retentionPolicy` is a child of
`spec.backup`, not of `barmanObjectStore`.

### The exposed backup credential — rotated 2026-10-05, one step left

**Status: closed. The exposed key is out of the cluster, out of git, and deleted from IAM.**

The IAM access key behind `s3-backup-secrets` (user `k8s-titan-pg-backups`) was pasted into a
chat transcript while the Secret was being authored, so the Secret could be sops-encrypted from
it. That key was `AKIA…CU67`, its secret access key fingerprinting `sha256:ad1d36e2efeb`. It
has been replaced: the live credential is `AKIA…4BSY` / `sha256:8392ba3863ac`, committed in
`5a2af0f` on 2026-10-05 and applied by Flux.

Fingerprints rather than values, here and in the script. The access key ID is an identifier and
last-four is how the AWS console displays one; the 12-hex digest is a truncated SHA-256 — a
comparison handle, not a recoverable value. The full access key ID is deliberately not written
down anywhere in this repo: `make leak-check` greps `AKIA[A-Z0-9]{16}` and rejects the commit
outright (demonstrated — dropping the literal in an untracked file fails the gate by filename),
and GitGuardian would flag it in CI on top of that.

**The rotation was verified from outside the repo, not assumed.** `kubectl -n databases logs
postgres-1` shows `barman-cloud-wal-archive` succeeding every five minutes across the change —
segment `…00000024` archived at `2026-10-06T09:30:07Z` in 0.79 s — with zero archive failure
lines in the preceding 24 h. The Secret's own digest, read back off the applied object through
`kubectl` + `base64 --decode`, equals the digest of the committed sops file, so git and the
cluster hold the same credential and nothing was hand-applied.

**A caveat I wrote here and then falsified.** This section claimed CNPG does not reliably pick
up a changed backup Secret (cloudnative-pg#4914) and that a pod roll might be needed. On this
target it did: `postgres-1` started `2026-10-04T21:11:19Z`, *before* the Secret changed, has
never rolled, and is archiving happily with the new key on 1.30.1. Keep running the archiving
check after a rotation — it is cheap and it is the only proof that matters — but do not roll a
pod on the theory that the Secret did not propagate. On 1.30.1 it propagates.

**Closed 2026-10-06: `AKIA…CU67` is deleted in IAM.** Until it was, the credential that went
through a transcript could still write to this bucket; the bucket policy is object-scoped to this
one bucket, which caps the blast radius at this bucket rather than the account, and that limits the
damage without making it safe.

Deleting it is also the proof that the rotation really took: if anything were still authenticating
with the superseded key, revoking it would have broken backups immediately. It did not. In the 24 h
after the deletion `postgres-1` archived 291 WAL segments with the most recent at `2026-10-06T20:25:20Z`,
zero failures, and the namespace holds no `Warning` events. Worth recording how that was read, because
the first pass looked alarming: grepping the pod log for `error|failed` returns 579 lines, and every
one of them is the *field name* `error_severity` inside a routine Postgres record — grouping by the
severity value gives 579 `LOG` and 596 `info`, and nothing above `LOG`. A grep that matches a key name
rather than a value is a check that cannot fail, which is the same trap as a `count(*)` assertion.

**How it landed is its own warning.** That rotation reached `main` inside a commit titled
`docs:` because `git add -A` swept a modified Secret off a working tree that was also carrying
doc edits — and no gate here would have caught it: `leak-check` does not decrypt sops files, so
a re-encrypted Secret is opaque noise to every offline check this repo has. If you rotate a
credential and edit docs in the same sitting, commit them separately, and read `git status`
before `git add -A`.

For the next rotation — create-then-delete, never delete-then-create:

1. Create a second access key for `k8s-titan-pg-backups` in IAM.
2. `./scripts/rotate-s3-backup-key.sh`, `make check`, merge.
3. Prove archiving is still advancing — `pg_stat_archiver` below, or a clean
   `./scripts/restore-drill.sh`.
4. Only after step 3 passes, delete the old key.

### Step 2: `./scripts/rotate-s3-backup-key.sh`

Run the script. It prompts for both values, so **read the new pair from your own terminal —
never from a paste.** Pasting a credential into a chat or an agent transcript is how the
current key got into the state this section exists to fix: the transcript is the leak, not
the repo.

It is a script rather than a block to paste because the operator's shell is **fish**, and the
bash form of this — `export VAR=`, `read -rs -p`, `[[ =~ ]]` — either means something
different or means nothing there. A shebang makes the login shell irrelevant.

What it does, in order:

- fingerprints the credential currently in the file: the access key ID in full (it is an
  identifier) and a truncated SHA-256 of the secret access key. A comparison handle, never
  the value — so "did the rotation actually land" is answerable without printing anything.
- prompts with `read -rs`, then **guards the shapes before encrypting**: `AKIA` + 16
  uppercase alphanumerics, and 40 chars of `[A-Za-z0-9/+=]`. An empty or truncated value
  encrypts perfectly and fails three namespaces away — the same class that produced two empty
  authentik passwords in Task 7. A rejected key leaves the Secret byte-identical; that was
  checked, not assumed.
- writes `apply/10-secrets/.staging.s3-backup.yaml` — git-ignored, and under
  `apply/10-secrets/` so `.sops.yaml`'s `path_regex` picks the right recipients, because sops
  chooses recipients from the file's own path rather than from your intent — encrypts it in
  place, and moves it over the real file. A `trap` removes the plaintext staging file on any
  exit path.
- carries `AWS_REGION: eu-west-1` forward deliberately: `s3Credentials.region` is a
  secret-key reference and there is no instance metadata on titan for barman to fall back to,
  so a rewrite that drops it breaks archiving while looking like a clean diff.
- prints the remaining steps, including step 3 below, so the create-then-delete order is in
  front of you at the moment you need it.

The whole script was dry-run against a throwaway copy of the Secret with a fake AKIA-shaped
pair before being committed.

Step 3 also gets a concrete command instead of "roll the instance pods". Note the counters
**before** you merge, from §1:

```bash
kubectl -n databases exec postgres-1 -c postgres -- \
  psql -U postgres -Atc "select archived_count, failed_count from pg_stat_archiver"
```

After the merge, force a segment switch and look again:

```bash
kubectl -n databases exec postgres-1 -c postgres -- psql -U postgres -Atc "select pg_switch_wal()"
sleep 20
kubectl -n databases exec postgres-1 -c postgres -- \
  psql -U postgres -Atc "select archived_count, last_archived_wal, last_archived_time,
                                failed_count, last_failed_time from pg_stat_archiver"
```

`archived_count` up and `failed_count` unchanged is the new credential working. If
`failed_count` moves, the instance manager may be holding the old credentials
(cloudnative-pg#4914) — though on 1.30.1 it propagated without a roll, so check for another
cause first:

```bash
kubectl -n databases delete pod postgres-1
```

That is a single-instance cluster, so it is a write outage of a few seconds and authentik
will error during it — which is why it is a response to stalled archiving and not a
reflex after a merge. Re-run the `pg_stat_archiver` query, and when the counters move, the
old key can finally be deleted in IAM.

Deleting the old key first leaves the cluster archiving to a bucket it can no longer write
to, and the failure is silent — see the next subsection.

### What "healthy" does not mean

`ContinuousArchiving: True` is not evidence that WAL is reaching the bucket. Before the
backup configuration existed, that condition was `True` on a cluster that was archiving
nothing — with no barman destination the archiver skips and still reports success. Trust
the archiver's own counters instead, which need nothing but kubectl and psql:

```bash
kubectl -n databases exec postgres-1 -c postgres -- \
  psql -U postgres -Atc "select archived_count, last_archived_wal, last_archived_time,
                                failed_count, last_failed_time from pg_stat_archiver"
```

CNPG ships WAL through `archive_command` calling `barman-cloud-wal-archive`, and Postgres
records every attempt there — so `archived_count` climbing and `failed_count` flat is the
credential working, and it is a strictly better signal than a bucket listing: it is the
archiver's own bookkeeping, it names the failing WAL, and it does not require the AWS CLI
on the machine you happen to be sitting at. (Needs pod `exec`, so an admin context —
`k8s-reader` cannot run it.)

Nothing to archive looks identical to archiving working, so force the question:

```bash
kubectl -n databases exec postgres-1 -c postgres -- \
  psql -U postgres -Atc "select pg_switch_wal()" && sleep 20
# …then re-run the query above: archived_count must have moved.
```

If you do have the AWS CLI somewhere, the object listing is still the independent
confirmation — `aws s3 ls s3://k8s-titan-pg-562256260016-eu-west-1-an --region eu-west-1
--recursive` — and it is the only check that proves the bytes landed where you think they
did rather than that Postgres believes they did.

One caveat to re-check at the 1.31 migration: `pg_stat_archiver` reflects `archive_command`,
and the Barman Cloud Plugin may not report through it the same way. See the deprecation
note in §2.

Also watch the PVC. Failed archiving does not raise an error; it accumulates WAL on a
volume whose `reclaimPolicy` is `Delete`.

---

## 2. Restore drill

`scripts/restore-drill.sh`. Needs an admin kubeconfig — the read-only `k8s-reader`
identity cannot run it and preflight says so explicitly rather than failing obscurely.

CNPG never restores over a running cluster: `bootstrap.recovery` builds a **new** cluster
from a base backup and replays WAL. So the drill stands a scratch cluster beside the live
one and the live cluster is never written to, apart from the nonce the seed step injects
into a throwaway `drill` database that is dropped on the way out.

Run it:

```bash
env DELETE=1 ./scripts/restore-drill.sh 2>&1 | tee /tmp/restore-drill-$(date +%F).log
```

What it does, in order: preflight (can this identity create Clusters? is there a
completed Backup? is the source Ready?) → seed a nonce → take a Backup and wait for
`completed` → stand up `postgres-drill` from the object store → wait `Ready` → assert the
nonce came back → clean up.

Why the assertion is a parameter and not a fixed query: the plan hard-coded
`select count(*) from core_user`, which requires authentik to exist, so the drill could
only run after Task 8 — the wrong order, since the cheapest time to drill a restore is
while an empty database means nothing can be lost. A restore of an empty database proves
mechanics; a restore that returns a value we deliberately wrote proves data survived the
round trip. Now that authentik is live, this is the assertion to prefer — it checks for a
named row in a real database rather than a nonce we planted:

```
env SEED=0 CHECK_DB=authentik \
  CHECK_SQL="select username from authentik_core_user where username='akadmin'" \
  EXPECT=akadmin ./scripts/restore-drill.sh
```

**The table is `authentik_core_user`, not `core_user`.** The first live run of this command
failed, and the reason was a wrong table name carried in from the plan, never checked. It is
knowable from authentik's own source: `authentik/core/apps.py` sets `label =
"authentik_core"`, the `User` model's `Meta` sets no `db_table`, so Django's default
`<app_label>_<model>` applies — and the sibling models in `core/models.py` that *do* set
`db_table` (`authentik_core_groupparentage`, `authentik_core_groupancestry`) confirm the
convention. Query `core_user` and psql answers `relation "core_user" does not exist`.

And the drill did not say that. It printed `== asserting the restore is real`, then cleanup,
and exited 1 with no verdict at all: under `set -e` the failing `got=$(kubectl exec … 2>&1)`
aborted the script before any comparison, and the `EXIT` trap deleted the scratch cluster
behind it. The `2>&1` had been capturing psql's error into a variable nothing ever printed.
Reproduced with a stub `kubectl` that exits non-zero, fixed with `if ! got=$(…)`, and the
three assertion paths are exercised again: a failed query now prints
`FAIL: the assertion query itself failed - this is NOT a value mismatch` followed by psql's
own text, which is the distinction the PITR section below spends a paragraph on.

**Do not write that assertion as `select count(*) from core_user`.** The script's bare
assertion is "the query returned at least one row", and `count(*)` always returns exactly
one row — holding `0`. Verified against the script with a stub `kubectl` that prints what
real `psql` prints:

```
PASS: select count(*) from core_user returned 1 row(s): 0
```

(That stub run predates the table-name correction above; the vacuousness is the finding, not
the table.)

That is a restore drill reporting success on a database with no users in it. The form above
cannot do that: no `akadmin` row means no rows, and the drill says
`FAIL: expected 'akadmin', got ''`. `SEED=0` because seeding a nonce would overwrite
`EXPECT` with the nonce; the two assertion styles do not mix.

A failed query and a mismatched value are different failures and must not look alike — see
the two bugs above, where the first live run produced neither message.

**Status of the authentik-shaped drill: passed.** The first attempt died on the two bugs
above; after both were fixed the same command went green on titan, 2026-10-05, operator
1.30.1 / Postgres 18.6, `DELETE=1`:

```
== preflight
   existing backup: drill-20261005092617 completed
   existing backup: drill-20261005100759 completed
   existing backup: drill-20261005104938 completed
   existing backup: drill-20261005183440 completed
   existing backup: postgres-manual completed
   source postgres Ready
   5 completed backup(s) present
== taking Backup drill-20261005184258
backup.postgresql.cnpg.io/drill-20261005184258 created
backup.postgresql.cnpg.io/drill-20261005184258 condition met
   backupId=20261005T184259 beginWal=000000010000000000000071
== standing up scratch cluster postgres-drill from s3://k8s-titan-pg-562256260016-eu-west-1-an/postgres
Warning: Native support for Barman Cloud backups and recovery is deprecated and will be
completely removed in CloudNativePG 1.31.0. Found usage in:
spec.externalClusters.0.barmanObjectStore. Please migrate existing clusters to the new
Barman Cloud Plugin to ensure a smooth transition.
cluster.postgresql.cnpg.io/postgres-drill created
== waiting for postgres-drill to become Ready (recovery can take minutes)
cluster.postgresql.cnpg.io/postgres-drill condition met
== asserting the restore is real
PASS: restored value matches the seeded nonce 'akadmin'
PASS: restore drill complete - postgres-drill recovered from s3://k8s-titan-pg-562256260016-eu-west-1-an/postgres
cleaned up scratch cluster postgres-drill
(Backup drill-20261005184258 left in databases as the record)
```

Two notes on that block, so it reads true later. `matches the seeded nonce 'akadmin'` is
loose wording — with `SEED=0` nothing was seeded, the value came from `EXPECT`; the script
now says "the expected value". And this is the run the two earlier ones could not be: a row
authentik itself created, in a real application database, came back out of the object store
through a rebuilt cluster.

Point-in-time is supported by the same script and is the drill worth doing second,
because PITR is what an incident actually needs:

```bash
env TARGET_TIME='2026-10-05T09:00:00+00:00' EXPECT=absent SEED=0 ./scripts/restore-drill.sh
```

That restores to before the nonce existed and asserts it is **absent** — proving
`recoveryTarget` is honoured rather than ignored, which a latest-recovery drill cannot
tell you.

### Recorded output from the first successful run

Run on titan, 2026-10-05, operator 1.30.1 / Postgres 18.6, `DELETE=1`:

```
== preflight
   existing backup: postgres-manual completed
   source postgres Ready
   1 completed backup(s) present
== seeding a nonce into postgres so the restore has something to prove
NOTICE:  database "drill" does not exist, skipping
INSERT 0 1
   seeded nonce: drill-20261005092617-353645
== taking Backup drill-20261005092617
backup.postgresql.cnpg.io/drill-20261005092617 created
backup.postgresql.cnpg.io/drill-20261005092617 condition met
   backupId=20261005T092619 beginWal=00000001000000000000000B
== standing up scratch cluster postgres-drill from s3://k8s-titan-pg-562256260016-eu-west-1-an/postgres
Warning: Native support for Barman Cloud backups and recovery is deprecated and will be
completely removed in CloudNativePG 1.31.0. Found usage in:
spec.externalClusters.0.barmanObjectStore. Please migrate existing clusters to the new
Barman Cloud Plugin to ensure a smooth transition.
cluster.postgresql.cnpg.io/postgres-drill created
== waiting for postgres-drill to become Ready (recovery can take minutes)
cluster.postgresql.cnpg.io/postgres-drill condition met
== asserting the restore is real
PASS: restored value matches the seeded nonce 'drill-20261005092617-353645'
PASS: restore drill complete - postgres-drill recovered from s3://k8s-titan-pg-562256260016-eu-west-1-an/postgres
cleaned up scratch cluster postgres-drill
(Backup drill-20261005092617 left in databases as the record)
```

A value written seconds earlier came back out of the object store through a rebuilt
cluster. That is the claim the whole backup section was making.

### The deprecation warning in that log is real debt

The webhook says native Barman Cloud support is removed in **1.31.0** — not "a future
release". The operator pin is 1.30.1, so this works today, but the migration to the
Barman Cloud Plugin is a prerequisite for the next operator minor, touching the
`Cluster`, the `ScheduledBackup`, and this drill's `externalClusters` entry at once. It is
tracked as forward debt in `apply/30-databases/postgres.yaml`; it is not a drive-by
edit and should not be attempted as a side effect of something else.

### Point-in-time — recorded

A latest-recovery drill cannot tell you whether `recoveryTarget` is honoured or ignored.
This is the pair that proves it: same bucket, same base backups, different target,
**opposite answers**.

Target `2026-10-05T09:00:00+00:00`, before the marker existed, asserting absence:

```
== preflight
   existing backup: drill-20261005092617 completed
   existing backup: drill-20261005100759 completed
   existing backup: postgres-manual completed
   source postgres Ready
   3 completed backup(s) present
== taking Backup drill-20261005104938
   backupId=20261005T104940 beginWal=000000010000000000000012
== standing up scratch cluster postgres-drill from s3://k8s-titan-pg-562256260016-eu-west-1-an/postgres
   recovering to a point in time: 2026-10-05T09:00:00+00:00 (exclusive)
cluster.postgresql.cnpg.io/postgres-drill created
== waiting for postgres-drill to become Ready (recovery can take minutes)
cluster.postgresql.cnpg.io/postgres-drill condition met
== asserting the restore is real
PASS: select datname from pg_database where datname='drill' returned no rows at target 2026-10-05T09:00:00+00:00, as expected
PASS: restore drill complete - postgres-drill recovered from s3://k8s-titan-pg-562256260016-eu-west-1-an/postgres
```

It restored from the 08:27 base backup and replayed WAL to 09:00, landing on a state where
the marker database had never been created. Combined with the latest-recovery run above,
where the same marker **is** present, `recoveryTarget` is demonstrably honoured.

**Choosing the target — a footgun I walked straight into.** The target must be *before the
marker was written* and *after the base backup it will restore from*. The seeded nonce
carries its own timestamp (`drill-20261005092617-353645` → 09:26:17), so read it off the
seed line rather than guessing. A first attempt used `date -d '-40 minutes'`, landed at
09:27:59 — 82 seconds *after* the marker — and correctly reported:

```
FAIL: expected no rows at this target, got: drill
```

That failure was the assertion working, not the restore failing. A relative "recently" is
the wrong frame of reference; the marker's own timestamp is the right one.

Also note the query: `select datname from pg_database where datname='drill'`, **not**
`psql -d drill`. At a target before the marker the database does not exist, and the
obvious query dies with a psql connection error that looks exactly like a broken restore
while meaning something entirely different.

### Housekeeping the drills leave behind

Each run leaves a `Backup` CR in `databases` (six after the runs recorded here — five from
drills plus the original manual one) and a real base
backup in the bucket. The object-store copies age out under `retentionPolicy: 30d`. Do not
"tidy" the CRs away to match: whether deleting a `Backup` CR also removes its object-store
data is undocumented upstream (cloudnative-pg#2328), so the CRs are the safe half.

### Offline checks that do not prove the restore works

`bash -n`, and the generated manifests validate against the vendored CRD via
`python3 tools/crd-field-check.py vendor/cnpg-crds`. Useful, and not a substitute: they
prove the YAML is well-formed, not that barman can read the bucket.

Two upstream-shape notes, because the plan got both wrong and the CRD is the authority:
`bootstrap.recovery` in 1.30.1 has no `barmanObjectStore` — the store config lives in an
`externalClusters[]` entry whose `name` must equal the source cluster name, since that
name is also the folder under the bucket. And the readiness condition is `Ready`, not
`Healthy`; `kubectl wait --for=condition=Healthy` never resolves and you only learn after
the full timeout.

---

## 3. `AUTHENTIK_SECRET_KEY` — do not rotate

`AUTHENTIK_SECRET_KEY` signs session cookies **and derives unique user IDs**. Changing it
invalidates every session and changes how user IDs derive. The chart's own comment says
do not change it after first install.

It lives in `apply/10-secrets/authentik-secrets.yaml`, and **that sops file is its only
backup** — there is no database copy of it. Losing it means losing authentik's identity
continuity, not just a secret. If it ever must change, that is a planned migration with the
user-ID implications worked out first, not an incident response.

The same file holds `AUTHENTIK_POSTGRESQL__PASSWORD`. `AUTHENTIK_BOOTSTRAP_PASSWORD` is
deliberately unused: it puts a plaintext password in a pod spec for no benefit, since the
first login is a human act anyway.

---

## 4. First admin

**Done — `akadmin` exists**, created through the browser flow on 2026-10-05. No admin
password ever entered git, and `AUTHENTIK_BOOTSTRAP_PASSWORD` remains deliberately unused
(§3).

How to tell from outside, without a credential: watch where `/` sends you.

```bash
curl -sS -o /dev/null -w '%{redirect_url}\n' https://auth.titan.arrieta.eu/
# before the admin existed:  .../setup      (and /setup bounced to /if/flow/initial-setup/)
# now:                      .../flows/-/default/authentication/?next=/
```

That chain ends at `/if/flow/default-authentication-flow/` with a `200`, which is the login
page, and it is the observable difference between an empty authentik and a provisioned one.

**A correction to what this section said when it was written.** It claimed that
`/if/flow/initial-setup/` answering `200` was the evidence no admin existed. Wrong, and it
was wrong the whole time: that path serves authentik's SPA shell — about 6 KB, `title:
authentik`, stage state resolved client-side — so its status code says nothing about whether
an admin exists. It answers `200` today with an admin in place. The redirect target of `/`
is the signal; the initial-setup status is not. The trailing slash really is required (404
without it), but that was about reaching the flow at all, and it still holds.

The log-out-and-log-back-in half of the flow is the intended test of
`AUTHENTIK_LISTEN__TRUSTED_PROXY_CIDRS`: a wrong CIDR produces a redirect loop or a
mixed-content block, far louder than anything in the logs. Much of it is already proven
without a browser — authentik's own access log records `scheme: https` for proxied requests
(§6) — but a real round trip through the login page is the half that exercises a session
cookie, and it is worth walking once deliberately rather than discovering on a phone.

---

## 5. Declarative authentik config — blueprints, and how long they take to land

authentik config-as-code on this install is **blueprints**, not CRDs. The chart pinned at
`2026.8.5` ships no `crds/` directory and has no `installCRDs` (verified at `2026.8.3`, when this
was written; the pin has moved and the `blueprints` mount keys are unchanged at `2026.8.5` —
`values.yaml:220-226`), so there is no `Provider` object
to commit; `blueprints.secrets: [<name>]` on the HelmRelease mounts a Secret into the worker at
`/blueprints/mounted/secret-<name>/`. The first thing using it is coder's OIDC app and provider:
template at `authentik/blueprints-coder.yaml`, rendered by `scripts/setup-coder-secrets.sh` into
the sops Secret, with `make oidc-check` comparing the two.

### Flux delivers it; authentik decides when it lands

**This is the finding that costs people the most confused minutes.** Flux applies the Secret, and
then authentik's own `blueprints_discovery` celery task notices the change and applies it. That
task is not fast and not regular. Measured over three hours on the live worker:

```
05:50:28   06:41:33   06:50:34   07:50:38   07:54:27
```

Gaps up to ~50 minutes. **So a merge is not an apply, and the gap can be half an hour.** Before
debugging a blueprint you think should have taken effect, ask the worker whether it has even looked:

```fish
kubectl -n auth logs deploy/authentik-worker --since=1h | grep -i "changed file"
```

`Applying blueprint due to changed file` names the path it read. Absent that line, nothing has been
attempted and the blueprint is not the thing to debug. **But the line proves dispatch, not success,**
and reading it as a verdict is a trap in its own right: `apply_blueprint` sets `status = ERROR`, saves,
and *returns without raising* when validation fails (`blueprints/v1/tasks.py:209-221`), so the celery
wrapper still logs `Task finished` with `exc: null` and the worker's stdout can stay entirely clean
while every entry in the blueprint failed. Measured on 2026-10-28 with `titan-identity`: `Creating new
blueprint instance from file`, `Applying blueprint due to changed file`, `Task finished exc: null`,
zero `warning` or `error` lines — and the only field that then distinguishes a clean apply from a
wholly failed one is `BlueprintInstance.status`. Read that, in the UI under Directory → Blueprints, or
over the API with the token below. To skip the wait, apply it directly — same
code path the periodic task uses:

```fish
kubectl -n auth exec deploy/authentik-worker -- ak apply_blueprint \
  /blueprints/mounted/secret-authentik-coder-blueprint/coder.yaml
```

**Every `exec` in this section needs an admin context.** The read-only `k8s-reader` identity is
`Forbidden` on `pods/exec`, `pods/portforward` and `get secret` — measured with
`kubectl auth can-i`, not inferred — so it cannot read a mounted blueprint, cannot run
`ak apply_blueprint`, and cannot reach authentik's blueprint status at all. It can read pod logs, and
that is where the diagnosis starts, not where it ends. That k8s-side limit is what
`titan-blueprint-reader` below exists to work around; it is a different identity, not a grant to
`k8s-reader`.

### A read-only path to blueprint status — applied, and the account exists

Written with `apply/50-apps/auth/identity-blueprint.yaml`, which declares an authentik role
`titan-blueprint-reader` holding exactly one permission — `authentik_blueprints.view_blueprintinstance`
— and a service account `svc-blueprint-status` holding that role. The authentik-side equivalent of
`k8s-reader`: enough to answer "did the worker apply my blueprint, and did it fail", never enough to
change anything.

One permission is the whole design, and it is the width the API actually asks for: authentik's default
DRF permission class is `authentik.rbac.permissions.ObjectPermissions` (`authentik/root/settings.py:248`),
whose `SAFE_METHODS` path requires `<app_label>.view_<model>` on a collection endpoint. An earlier draft
also granted `authentik_core.view_user` and `authentik_core.view_group` so a failed entry could be
named; nothing below needs them, the blueprint list returns only name / path / status / last_applied,
and on a token meant to be handed to an agent those two are org-wide user enumeration. They were
dropped in review — see the comment on the role itself before adding anything back.

**What is proven and what is not.** The blueprint is applied — `titan-identity` reached status
`successful` at 16:50:37Z on 2026-10-28, so the role `titan-blueprint-reader` and the service account
`svc-blueprint-status` both exist in the instance now. **No token has been minted**, and the procedure
below has still never been run end to end: it is derived from the pinned `version/2026.8.5` source,
not from a drilled run, so treat the minting steps as a procedure to verify the first time someone
needs them. Nothing consumes the token yet, and per the rule in the blueprint's own header, if nothing
ever consumes it, do not mint it.

What it answers once a token exists:

```fish
# GET /api/v3/managed/blueprints/ — the route is `managed/blueprints` in
# authentik/blueprints/urls.py at version/2026.8.5; the list is what the UI's blueprint page is.
curl -sS -H "Authorization: Bearer $AUTHENTIK_STATUS_TOKEN" \
  https://auth.titan.arrieta.eu/api/v3/managed/blueprints/ \
  | jq '.results[] | {name, path, status, last_applied}'
```

`status` is one of `successful | warning | error | orphaned | unknown` (`BlueprintInstanceStatus`,
`authentik/blueprints/models.py:46`). A blueprint the worker never discovered is **absent from this
list entirely** — that is the runbook's oldest finding, and it is why absence and failure are two
different answers here and only `ak apply_blueprint` plus the worker log separates them.

Minting the token, in order, with the two traps in it:

1. The account must exist first, i.e. the blueprint must have landed. Check with the `curl` above
   against a known-good token, or the UI (Directory → Users → `svc-blueprint-status`).
2. `POST /api/v3/core/tokens/` with `{"identifier": …, "intent": "api", "user": "<uuid>",
   "expiring": false}`. `expiring: false` is not cosmetic: the API forces `expires` to the tenant
   default for `intent: api` (`authentik/core/api/tokens.py`, `TokenSerializer.validate`), and the
   default manager filters out `expires__lt=now(), expiring=True` — a token left expiring is
   silently gone one day later and the next diagnosis fails with a 401 that looks like a revoked
   grant.
3. **The create response does not contain the key.** `TokenSerializer` has no `key` field outside
   the blueprint context; the key comes from `GET /api/v3/core/tokens/<identifier>/view_key/`,
   which needs `authentik_core.view_token_key` — deliberately *not* in `titan-blueprint-reader`, so
   minting is an admin act and reading is not. That is the split that makes the role safe to hand to
   an agent.

The token then goes in `apply/10-secrets/`, sops-encrypted, `stringData` — never in a blueprint, per
the rule written into the header of `identity-blueprint.yaml`. What consumes it is not wired yet; if
nothing consumes it, do not mint it.

### A brand-new blueprint can be missed by the very pass that should have caught it

The lag above is at least visible in the logs. This one was not — see the signature found two days
later further down — and it cost an hour of live breakage on 2026-10-20 when
`authentik-grafana-blueprint` was added.

What happened: Flux applied the Secret, Stakater Reloader restarted the worker for it, and the
worker's startup `blueprints_discovery` ran ten seconds after the container started and **did not
create the instance**. The file was demonstrably on disk — `wc -c` inside the worker showed
`grafana.yaml` at 5637 bytes, same kubelet `..data` symlink layout as the accepted `tesla.yaml` —
the pod spec carried the volume, and `apply_blueprint` finished with `exc: null`. Nothing anywhere
reported a failure. The blueprint list simply had no `titan-grafana` in it.

A second worker restart picked it up immediately. What is *proven* is the sequence: mounted file,
discovery pass that skipped it, restart that ingested it. What is *inferred* is the mechanism — a race
between the startup pass and kubelet finishing the secret volume's atomic swap. The ten-second gap
fits and nothing else found so far explains it, but it was not caught in the act.

So, when a blueprint you just added is absent rather than failed:

1. `exec` in and check the file is really there and non-empty — `wc -c /blueprints/mounted/*/*.yaml`
   compares all of them at once, which also shows whether the Secret-mounted ones are laid out the way
   the ConfigMap one is.
2. Present and non-empty → either wait for the next beat pass, which recovers it unattended (measured
   21 min, see the next subsection), or apply it directly with `ak apply_blueprint` above. Force it
   when the gap has a price — a client-secret rotation, an app someone is waiting on — not merely
   because the UI still has no entry. **Read the redaction note below first**; a validation failure
   prints the client secret.
3. Absent or zero bytes → the problem is the Secret or the mount, not the blueprint.

The asymmetry that makes this worth writing down: a blueprint that *fails* validation leaves a
BlueprintInstance with an error in the UI, and a blueprint that was *never seen* leaves nothing at all.
"It is not in the list" is therefore a different diagnosis from "it is in the list and red", and the
existing `grep -i "changed file"` check does not distinguish them — both produce no such line.

### The startup skip does leave a trace, and the beat recovers it on its own

Found 2026-10-22 while adding `authentik-mealie-blueprint`, which was mounted the same way grafana's
was and went through the same startup skip. The worker log, verbatim:

```
20:28:54  worker restarts (Reloader on the new Secret), migrations run
20:29:01  blueprints_discovery ENQUEUED  id=d17ab58a   ← never started
20:50:03  blueprints_discovery enqueued  id=b3706912 → started → finished
20:50:03  "Creating new blueprint instance from file
           mounted/secret-authentik-mealie-blueprint/mealie.yaml"
20:50:03  "Applying blueprint due to changed file"
```

**The skip is visible after all.** The subsection above says it is not, and
`docs/teslamate-runbook.md` repeats that. It shows as an *enqueued task that never starts*. Every
other task enqueued in that same second logged `Task started` and `Task finished`; `d17ab58a` has
only the enqueue, anywhere in the log. The read-only identity can see this — it is a pod log, no
`exec` needed:

```fish
kubectl -n auth logs deploy/authentik-worker | grep blueprints_discovery
# enqueued + started + finished  → the pass ran
# enqueued with no started       → the pass was lost. This is what the grafana episode looked like.
```

**And the beat recovers it without anyone forcing anything.** Nobody touched the UI here; 21 minutes
later the periodic pass created the instance, applied it, and the provider answered `200`. The
grafana episode is not counter-evidence — that one was fixed by a second worker restart before a beat
pass got the chance, so nothing above is contradicted. What changes is the default action: waiting is
a legitimate answer, and `ak apply_blueprint` is a shortcut for impatience or a costly gap rather than
the only way back. Note the two ends still move at different speeds during a rotation, so that case
keeps needing the manual apply — see the rotation section.

### Loki proves dispatch and beat-recovery. It cannot prove the verdict

Confirmed 2026-10-29 against casa's Loki while three blueprints landed, because "the log is quiet" is
tempting to read as "it applied" and it is not.

The pod logs are pushed to `https://loki.local.arrieta.eu` by promtail, so the same enqueued/started/
finished evidence the section above describes is queryable across worker pod replacements — which the
pod log is not, since the pod that lost the pass is gone:

```fish
set END (date +%s)000000000
set START (math (date +%s) - 5400)000000000
curl -sS -G https://loki.local.arrieta.eu/loki/api/v1/query_range \
  --data-urlencode 'query={cluster="titan", namespace="auth", pod=~"authentik-worker.*"} |~ "blueprints_discovery|Applying blueprint"' \
  --data-urlencode "start=$START" --data-urlencode "end=$END" --data-urlencode limit=200
```

That is how the 10:42:09 enqueue with no start was found eight minutes later to have been recovered by
the 10:50:09 beat pass, which then logged `Applying blueprint due to changed file` for all three
instances with `exc: null` and not one warning anywhere in the window.

**And it is still not the verdict.** In `authentik/blueprints/v1/tasks.py`, a blueprint that fails
validation does this:

```python
if not valid:
    instance.status = BlueprintInstanceStatus.ERROR
    instance.save()
    self.logs(logs)          # ← the task record, not stdout
    return
```

`self.logs()` attaches the captured Django logs to the **task record** — the UI's Tasks view — not to
the stream promtail ships. So a failed apply and a clean apply produce the *same* pod log: one
`Applying blueprint due to changed file` line and a task that finished with `exc: null`. Loki silence
therefore cannot distinguish them, and neither can `kubectl logs`.

The verdict remains `BlueprintInstance.status` in the UI. What Loki adds is the ability to see the
dispatch and the beat recovery after the pod that performed them has been replaced, which is the half
that used to be unrecoverable.

### How to tell the provider actually exists — mind the trailing slash

```fish
curl -s -o /dev/null -w '%{http_code}\n' \
  https://auth.titan.arrieta.eu/application/o/coder/.well-known/openid-configuration
```

`200` means the OIDC client is live; the document's `issuer` should read
`https://auth.titan.arrieta.eu/application/o/coder/`, which is the exact string coder is configured
with, so the two can be compared rather than assumed equal.

**Do not put a trailing slash on that path.** `…/.well-known/openid-configuration/` returns `404` on
this install while the unsuffixed form returns `200`. That false negative cost a full debugging cycle
here: coder was already `1/1 Running` and serving traffic while the slashed URL insisted its provider
did not exist. A probe that reports a working thing as missing is worse than no probe, because it
redirects attention to the wrong component — and coder *refuses to start* until OIDC discovery
succeeds, so "coder is Running" was itself the answer, available without any endpoint at all.

### A second probe, for when the client itself is the question

The discovery document answers "is the provider live" but not "does authentik recognise this client".
Those differ when the provider exists but the client id Grafana or coder holds is not the one authentik
stored — a half-applied rotation, or two copies of a credential that drifted. Ask authentik directly,
with the client id from the consumer's Secret:

```fish
curl -s -o /dev/null -w '%{http_code}\n' \
  "https://auth.titan.arrieta.eu/application/o/authorize/?client_id=<id>&response_type=code&redirect_uri=<registered%20uri>&scope=openid"
```

The page text discriminates, and it is worth reading the body rather than the status code — both
outcomes can return `400`:

| body text | meaning |
|---|---|
| `Client ID Error — the client identifier (client_id) is missing or invalid` | authentik has no such client. The blueprint has not landed, or the id is wrong. |
| `Redirect URI Error` | the client **is** known; it got past client validation and rejected the redirect. Different bug. |
| `302` into a flow | fully accepted. |

Run it against a known-good client too (coder's) as a control. Without that baseline the probe looks
like it returns nothing useful, because a well-formed request for a *known* client and a malformed one
both redirect or both 400 depending on what you omit.

**The client id has to be the real one, and for blueprint-rendered clients the read-only identity
cannot get it.** Every client here is rendered from `${..._OIDC_CLIENT_ID}` by its setup script, and
those are `uuid4()` values that live only in a Secret — `scripts/setup-mealie-secrets.sh:58` and its
siblings. `k8s-reader` is Forbidden on `get secret`, so the id is unavailable, and a guessed id drawn
from the app name produces `Client ID Error` for a provider that is demonstrably live. Measured
2026-10-22: `client_id=mealie` returned `Client ID Error` while that same provider's discovery document
returned `200` and the worker log showed the apply — because the real id is a UUID. Take the id from
the consumer's own env, or skip this probe and use the discovery document plus the worker log, which
need no credential at all.

### Redact before pasting any of it

`ak apply_blueprint` dumps the whole entry — **including `client_secret`, in plaintext** — when
validation fails. That is how coder's secret went into a chat transcript and had to be rotated.
Always filter:

```fish
... ak apply_blueprint --dry-run <path> 2>&1 | sed -E 's/[a-f0-9]{64}/REDACTED/g' | tail -20
```

### Two failure modes, both from writing references from memory

The importer rewrites a value only when it is a key in its own `pk_map`, which is built from entries
*inside the same blueprint*. Everything else reaches the serializer verbatim. That makes exactly two
ways to get a relation wrong, and they fail very differently:

| mistake | symptom |
|---|---|
| a lookup dict where a pk is wanted — `authorization_flow: {slug: x}` | loud: `"{'slug': 'x'}" is not a valid UUID` |
| a `!Find` whose filter matches nothing | **silent**: resolves to `None`, then `property_mappings: [None]`, a validation failure that names the field but not the cause |

The second one is the trap. `!Find` is `apps.get_model(...).filter(...).first()` — a miss is a
`None`, not an error. The real example: `default-scopes` was written as though it were a thing, and
no `ScopeMapping` by that name exists. authentik ships **one mapping per scope**, each with a stable
`managed:` id, and the display names are UI-editable and localisable, so key on the id:

```yaml
property_mappings:
  - !Find [authentik_providers_oauth2.scopemapping, [managed, goauthentik.io/providers/oauth2/scope-openid]]
  - !Find [..., scope-email]
  - !Find [..., scope-profile]
```

The rule this leaves behind: **every `!Find` gets checked against source or the live instance before
it ships**, because a wrong one is indistinguishable from a right one until the apply. Model names
come from each app's `apps.py` label (`authentik_providers_oauth2.scopemapping` is the oauth2 app,
not the policies app whose class it inherits from), and the default objects are declared in
authentik's own `blueprints/system/*.yaml`.

### The third failure mode: `signing_key`, optional until it isn't

A `!Find` that resolves and a field that is present can still be the wrong config. The provider
applied cleanly, the OIDC discovery endpoint answered `200`, and the first real login died at the
last step:

```
oidc: malformed jwt: unexpected signature algorithm "HS256"; expected ["RS256"]
```

authentik's own code is the explanation, `providers/oauth2/models.py:358-359`:

```python
if not self.signing_key:
    # No Certificate at all, assume HS256
```

With no signing key the provider HMACs the `id_token` with the **client_secret**. coder's go-oidc
verifier expects RS256 from the provider JWKS and rejects the token. The fix is one line, pointing
at the certificate authentik already creates and reconciles (`authentik/crypto/apps.py`:
`MANAGED_KEY` at `:10`, "authentik Internal JWT Certificate" at `:23`):

```yaml
signing_key: !Find [authentik_crypto.certificatekeypair, [managed, goauthentik.io/crypto/jwt-managed]]
```

The provider JWKS is the cheap external check, and it is worth capturing **before** a change for
once, so the after means something:

```fish
curl -s https://auth.titan.arrieta.eu/application/o/coder/.well-known/openid-configuration \
  | python3 -c 'import sys,json;print(json.load(sys.stdin)["jwks_uri"])' | xargs curl -s
# expect: kty=RSA alg=RS256 use=sig. An empty key list means no signing key is set.
```

**What this generalises to:** OIDC discovery `200`, coder `Ready`, all five stages `Healthy`,
`oidc-check` 9/9 — every one of those stayed green while login was broken. None of them completes a
code exchange. Checks made of config agreement can never prove a token verifies; the last hop of an
auth chain is only provable by authenticating.

### Cold start: coder's `/setup` page has no OIDC button

On a deployment with zero users, `/` redirects to `/setup`, and `SetupPageView.tsx` at the pinned
`v2.37.4` is a **password-only** form — username, email, password. There is no OIDC control there,
even though `oidc.enabled` is `true` and the backend fully supports first-user OIDC signup
(`coderd/userauth.go:1783-1785` allows it "regardless of whether signups are enabled", and
`:1849-1851` grants that user the owner role). The UI just never offers the route.

The route is public and works; drive it directly:

```
https://coder.titan.arrieta.eu/api/v2/users/oidc/callback
```

It 307s to authentik with a correct `client_id`, `redirect_uri`, scopes and a `state` cookie, and
the return leg creates the first user. Confirmed working 2026-10-07.

Do not conclude from `/setup` that a local admin is required. And note the interaction with
`CODER_DISABLE_PASSWORD_AUTH`: coder's docs promise owners can still password-login under that flag,
but `coderd/userauth.go:599-605` blocks it unconditionally — the comment describes a carve-out the
`if` does not implement, on `v2.37.4` and on `main` alike. Since `coder server create-admin-user`
makes a *password* owner (`cli/server_createadminuser.go:199-200`) and no session token, setting
that flag before a working break-glass exists is how you actually lock yourself out.

One incidental confirmation from that file: the email scope mapping's expression returns
`"email_verified": False`. So `CODER_OIDC_IGNORE_EMAIL_VERIFIED=true` is load-bearing, not defensive
— without it coder rejects a login over an address authentik deliberately marks unverified.

### Rotating coder's OIDC client secret

Done once on 2026-10-07, because `ak apply_blueprint` had printed the old value into a transcript —
the same class of exposure as the S3 key, and the same remedy.

**There is an unavoidable window in which logins fail, and it is worth understanding before anyone
rotates this a second time.** `OAuth2Provider.client_secret` is a single field, not a list, so
authentik cannot hold old and new at once. And coder reads it from `secretKeyRef` **into its
environment at container start** — with no checksum annotation anywhere in the coder chart's
templates, changing the Secret does not roll the pod. The two ends therefore move at different speeds
and never move together:

| step | who moves | when |
|---|---|---|
| merge | both Secrets land in the cluster | Flux, seconds |
| authentik uses the new secret | its own `blueprints_discovery` | **up to ~50 min later**, or now if applied by hand |
| coder uses the new secret | whoever runs `rollout restart` | **never, unless someone does it** |

Between rows two and three, new OIDC logins fail with `invalid_client` at the token endpoint.
Existing sessions survive, so it is a login outage rather than a lockout. This rotation was free only
because it landed before the first real login; **the next one is a planned interruption and should be
announced as one.**

The sequence, ordered to keep the window as short as it can be:

```fish
# 1. Re-render with the DB password and client id pinned, so the client secret is the only thing that
#    changes. Leaving CODER_OIDC_CLIENT_SECRET unset is what makes the script generate a fresh one.
env CODER_DB_PASSWORD=… CODER_OIDC_CLIENT_ID=… FORCE=1 ./scripts/setup-coder-secrets.sh
#    It prints which values were reused vs generated, and only ever a truncated SHA-256.

# 2. Merge, then make authentik apply it instead of waiting on discovery:
kubectl -n auth exec deploy/authentik-worker -- ak apply_blueprint \
  /blueprints/mounted/secret-authentik-coder-blueprint/coder.yaml 2>&1 \
  | sed -E 's/[a-f0-9]{64}/REDACTED/g' | tail -5

# 3. Close the gap immediately:
kubectl -n coder rollout restart deploy/coder
```

What proves it worked is a real login, not a status condition: neither side reports a mismatched
client secret until somebody tries to exchange a code, so every intermediate check can be green while
the pair disagrees.

**This manual restart was a gap, and it is now closed.** Reloader is live (`reloader-reloader-*` in
`apps`, chart `2.2.18`, scoped to the `apps` and `coder` namespaces with a namespaced `Role` and no
`ClusterRole`), and `apply/50-apps/coder/coder.yaml` carries
`secret.reloader.stakater.com/reload: coder-secrets` on the pod template — so a change to that
Secret rolls coder by itself. `docs/superpowers/specs/2026-10-07-titan-reloader-design.md` is the
design. Step 3 above is now belt-and-braces rather than mandatory; if Reloader is ever removed, the
`rollout restart` becomes load-bearing again and nothing will warn you.

---

## 6. What the read-only identity can and cannot prove

`docs/agent-read-access.md` mints `k8s-reader`, and it is the right identity for a routine
check. Its limit is worth naming, because the obvious verification command fails in a way
that reads like a broken cluster:

```
Error from server (Forbidden): clusters.postgresql.cnpg.io "postgres" is forbidden:
User "system:serviceaccount:k8s-reader:k8s-reader" cannot get resource "clusters" ...
```

`k8s-reader` cannot read `postgresql.cnpg.io` objects or any Secret. So `get cluster`,
`get database`, `get backup` and `get secret titan-tls` need an admin context. Everything
below is what the read-only identity proves by effect, recorded 2026-10-05 at
`main@c4e683f`, and it is a genuinely strong set:

> **Updated 2026-10-19.** The first half of that is no longer true: `k8s-reader` now has
> `get/list/watch` on `clusters`, `databases`, `databaseroles`, `backups`, `scheduledbackups` and
> `poolers`, so `kubectl -n databases get cluster` works from the read-only identity and the
> Forbidden error above is history. Secrets are still refused, and CNPG CRs name Secrets rather
> than carry them, so nothing secret crossed with the grant. The by-effect table below is kept
> unchanged on purpose — it is a dated record of what was observed, and proving health by effect
> is still better evidence than reading a status field an operator wrote.

| check | observed |
|---|---|
| `kubectl -n flux-system get kustomization` | all five stages `Ready=True`, applied at `main@c4e683f` |
| `kubectl get helmrelease -A` | five `Ready=True`: cert-manager, its OVH webhook, reflector, cloudnative-pg, authentik |
| `kubectl -n certificates get certificate` | `titan-wildcard Ready=True` → `titan-tls` |
| TLS handshake to `auth.titan.arrieta.eu:443` | leaf `CN=titan.arrieta.eu`, SAN `*.titan.arrieta.eu` + `titan.arrieta.eu`, issuer Let's Encrypt, verifies against the system CA — so Reflector's copy in `auth` exists and is current |
| `kubectl -n databases get pods,pvc` | `postgres-1` `1/1 Running`, PVC `Bound` 10Gi `local-path`, **zero Warning events** in the namespace |
| `kubectl -n auth get pods` | `authentik-server` + `authentik-worker` `1/1 Running` |
| `https://auth.titan.arrieta.eu/` | `302 → /setup`, `/setup` `302 → /if/flow/initial-setup/`, that `200` — the *no admin yet* shape; see §4 for what it looks like now |
| server access log | `"scheme": "https"` on a request that arrived through Traefik from the pod CIDR |

That last row is the trusted-proxy proof. authentik 2026.8 honours `X-Forwarded-Proto`
only from listed CIDRs, and a wrong list makes it see plain HTTP behind TLS — which shows
up as a redirect loop or a mixed-content block rather than as a log line. The log saying
`scheme: https` for a proxied request means `10.62.0.0/16` is being trusted, which is the
value in `apply/50-apps/auth/authentik.yaml`.

What the read-only identity cannot reach, and so is **not** proven by this table: the
`Cluster`'s own conditions, `Database`/`DatabaseRole` `Synced`, and whether WAL is still
reaching the bucket. For the first two, an admin context, or `kubectl -n databases exec
postgres-1 -c postgres -- psql -U postgres -c '\du authentik'`. For the last, list the
bucket (§1) — never the `ContinuousArchiving` condition.

---

## 7. Open decision carried forward

*Superseded 2026-10-07, and kept rather than deleted because the reasoning still matters.*

The decision was: authentik **blueprint export**, not OAuth federation. coder's OIDC application and
provider are now declared in git (§5) — the mechanism this section called "the right long-term
answer" and deferred as speculative.

What remains genuinely open is the narrower thing the deferral was protecting. This is one blueprint
for one service, added because a manual UI step was the only human prerequisite blocking coder. It is
not a migration plan for the rest of authentik's config and nothing here says that config should
move. The trigger that would make it one is a second service needing declarative setup — at which
point the template / `oidc-check` / render-script pattern in §5 is the thing to generalise, and the
`blueprints_discovery` cadence stops being a footnote and becomes a real argument for an apply hook.

---

## 8. `CODER_DISABLE_PASSWORD_AUTH` — tested, the carve-out is a myth, and what that changes

Coder's configuration reference promises, in the option's own description:

> "Any user with the owner role will be able to sign in with their password regardless of this
> setting to avoid potential lock out."

**It does not do that, and this is now measured rather than read.** On 2026-10-07, with a
`create-admin-user` owner in place:

| `CODER_DISABLE_PASSWORD_AUTH` | `POST /api/v2/users/login` as that owner | |
|---|---|---|
| `true` | **403** | `"Password authentication is disabled."` |
| unset | **201** | session issued |

The code agrees with the measurement, `coderd/userauth.go:599-605`:

```go
// If password authentication is disabled and the user does not have the
// owner role, block the request.
if api.DeploymentValues.DisablePasswordAuth {
```

The comment describes an owner carve-out; the `if` has no owner condition. All three enforcement
sites (`:244`, `:351`, `:601`) are unconditional, and `main` is identical to the pinned `v2.37.4`,
so there is no version to wait for. PR #5991, which introduced the flag, describes the carve-out as
the feature's purpose — "prevents the password login endpoint from working unless the user has the
'owner' role".

**The flag is set anyway — deliberately, and with the escape hatch moved somewhere it still works.**
`coder server create-admin-user` writes a *password* owner (`cli/server_createadminuser.go:199-200`)
and issues no session token, so under the flag that account cannot sign in. But it lives in the
database, not in the env var, and the flag is one environment variable on a Deployment. The break-glass
is therefore: **turn the flag off, use the admin, turn it back on.** That is what
`CODER_DISABLE_PASSWORD_AUTH: "true"` in `apply/50-apps/coder/coder.yaml` means, and §8.1 is the
procedure.

What the flag buys: no local account can be used while the system is healthy, so a forgotten password
is not a standing door, and the login page offers exactly one way in.

### 8.1 If you are locked out: enable password auth

The realistic trigger is authentik being down or misconfigured, not a forgotten password. Do this:

```fish
# 1. Flip it live. This changes the pod template, so coder rolls itself; ~40s.
kubectl -n coder set env deploy/coder CODER_DISABLE_PASSWORD_AUTH=false

# 2. The login page now renders the password form again — SignInForm.tsx:29 keys off
#    /api/v2/users/authmethods, which flips with the flag. Sign in as the break-glass admin.
#    Or without a browser:
curl -s -X POST https://coder.titan.arrieta.eu/api/v2/users/login \
  -H 'Content-Type: application/json' -d '{"email":"…","password":"…"}'
#    201 = session token in the body. 403 = the flag is not actually off yet.

# 3. Fix the OIDC problem. Then put the flag back, by hand, see below.
kubectl -n coder set env deploy/coder CODER_DISABLE_PASSWORD_AUTH=true
```

**Step 3 is not optional and Flux will not do it for you.** `driftDetection.mode` is `enabled`, which
is notify-only, and Helm patches new-vs-old rather than live-vs-desired — so a value you changed by
hand stays changed forever, including `false`. The next `helm upgrade` will not restore it. Either set
it back explicitly as above, or force git to win:

```fish
kubectl -n coder annotate --overwrite helmrelease coder reconcile.fluxcd.io/requestedAt="$(date +%s)"
# then confirm git and reality agree:
kubectl -n coder get deploy coder -o jsonpath='{.spec.template.spec.containers[0].env}' \
  | tr ',' '\n' | grep -A1 DISABLE_PASSWORD
```

While the flag is off, the only password-loginable account is the break-glass admin, whose password is
in the password manager and nowhere in this repo. That is a small, deliberate, temporary window — but
it is a window, so close it in the same session that opened it.

And note what the flag does **not** protect: it does not survive someone editing the Deployment, and
§9 shows this cluster does not notice when that happens.

**The break-glass exists now** — created with `kubectl -n coder exec -it deploy/coder -- coder server
create-admin-user`, which needs `-it` because it prompts, and which must not be given
`--postgres-url` since `CODER_PG_CONNECTION_URL` is already in the pod env and the flag would put the
DB password on a command line. Its password lives only in the operator's password manager; nothing in
this repo can show it. Re-test it with the `curl` above every few months — an untested break-glass is
a rumour.

## 9. Hand-edits to Helm-managed Deployments are **not** reverted

*Discovered the hard way in the same session as §8, by assuming otherwise.*

The working assumption — "poke it live, Flux will put it back" — is false here:

```console
driftDetection: {"mode":"enabled"}   # notify-only. It reports drift; it does not fix it.
Drifted: NoDriftDetected             # and it did not even report this one
# env var still present 5h later, 30m interval, after two manual reconcile nudges
```

Helm patches new-vs-old, not live-vs-desired, so an env var added out of band survives every
subsequent `helm upgrade` indefinitely. `kubectl -n coder edit deploy coder` therefore makes a change
that is **permanent and invisible to git**, which is the worst combination available on this cluster.

To remove one, say so explicitly:

```fish
kubectl -n coder set env deploy/coder CODER_DISABLE_PASSWORD_AUTH-
```

Two consequences worth deciding about deliberately rather than discovering under pressure:

1. Either set `driftDetection.mode: fix` on the HelmReleases, or accept that live drift persists and
   treat `kubectl edit` as a last resort rather than a diagnostic. Today the repo neither does the
   first nor documents the second.
2. Any incident where someone "temporarily" edits a deployment leaves that state behind after the
   incident is closed. `make dry-run` compares git to the chart and cannot see this class of drift at
   all.


## 10. Recovering a coder workspace home after its PVC is deleted — **drilled 2026-10-07**

Spec §9.2 refused to accept "a deleted PVC keeps its bytes" on reasoning, and required the plan to
show the bytes *and* show them recoverable. Both halves are now done, and the second half is where
the surprise is.

### What `Retain` actually buys

It preserves the **bytes**, and nothing else. After `kubectl delete pvc`:

```
$ kubectl get pv pvc-e057553e-… -o jsonpath='{.status.phase}'
Released
$ ls -l /var/lib/rancher/k3s/storage/pvc-e057553e-…_coder-workspaces_coder-1258c2a6-…-home/RETAIN-DRILL.txt
-rw-r--r-- 1 javier 1000 34 Oct  7 19:23 …/RETAIN-DRILL.txt
```

What it does **not** do is reattach. Starting the workspace after the deletion provisioned a brand
new 40 Gi volume, the pod came up `Running`, coder reported the workspace `Started`, home-manager
ran happily against an empty home, and the marker was simply gone:

```
coder-1258c2a6-…-home   Bound   pvc-bc377888-…     ← a fresh volume, not the retained one
$ ls ~/RETAIN-DRILL.txt
ls: cannot access '/home/coder/RETAIN-DRILL.txt': No such file or directory
```

**This is the failure mode to internalise: a lost home looks like a healthy workspace.** Nothing
errors. The user gets an empty dotless home and the retained bytes sit in a directory no object
points at. Spec §9.2's mitigation is real but it is *not* automatic, and §13's C2 override is only
defensible with that caveat attached.

### Recovery procedure (this is what was run, in this order)

```bash
coder stop dev --yes
kubectl -n coder-workspaces delete pvc coder-<workspaceID>-home
kubectl delete pv <released-pv> <any-newer-pv-the-provisioner-made>

# The PV must exist BEFORE the claim, so the binder has something to match.
kubectl apply -f - <<'PV'
apiVersion: v1
kind: PersistentVolume
metadata:
  name: coder-home-recovered
spec:
  capacity: { storage: 40Gi }
  accessModes: ["ReadWriteOnce"]
  storageClassName: local-path-retain
  claimRef:
    namespace: coder-workspaces
    name: coder-<workspaceID>-home
  hostPath:
    path: /var/lib/rancher/k3s/storage/<released-pv>_<ns>_<claim>
PV

kubectl get pv coder-home-recovered -o jsonpath='{.status.phase}'   # must say Available
coder start dev --yes
```

`claimRef` is what makes the binder pick this instead of provisioning. The `Available` check is the
checkpoint — do not start the workspace until it prints it.

Result:

```
coder-1258c2a6-…-home   Bound   coder-home-recovered
$ cat ~/RETAIN-DRILL.txt
RETAIN-DRILL 2026-10-07T19:23:09Z          # sha256 24e05217decf1dcc, unchanged
```

### The trap in it

**The recovery races the provisioner.** If you start the workspace before hand-writing the PV, the
provisioner wins, you get an empty volume, and the orphaned directory is now *harder* to find because
a healthy-looking workspace is sitting on top of the wrong data. Two rules follow:

1. If a workspace home vanishes, **stop it immediately** — do not restart it — and check for a
   `Released` PV before anything else.
2. `kubectl get pv | grep Released` is a diagnostic worth running routinely; a `Released` PV on this
   cluster means data is sitting on disk with nothing pointing at it.

Finding the directory when the PV object is already gone: the path is
`/var/lib/rancher/k3s/storage/<pv-name>_<namespace>_<claim-name>`, so `ls` that directory and match
on the claim suffix.

## 11. Google social login — four wrong facts, all caught by running it

Landed 2026-10-11 (`authentik/blueprints-google.yaml`). Every one of these was read confidently from
source and wrong, and none of them produced a visible failure anywhere a dashboard would show.

| Wrong belief | Reality | How it surfaced |
|---|---|---|
| model `googleoauthsource` | `GoogleOAuthSource` is `abstract = True` — a type marker, not a table. Use `oauthsource` + `provider_type: google` | `ak apply_blueprint` in the foreground |
| `pkce: s256` | `PKCEMethod` is `none`/`plain`/`S256` — inconsistent with itself, so the lowercase value is rejected | same |
| `pkce: S256` does something | It does not. `clients/oauth2.py` uses `source_type.pkce` and only honours the per-source override when `urls_customizable` is True; GoogleType sets neither, so it inherits `NONE`/`False` | reading `clients/oauth2.py` after the redirect carried no `code_challenge` |
| callback is `/application/o/google/callback/` | That is authentik's **provider** mountpoint (coder's OIDC discovery answers there). Sources mount at `source/oauth/` → `/source/oauth/callback/google/` | the route 404'd and `application/o/coder/.well-known` did not |
| creating the source puts it on the login page | It does not. The **Identification stage** has its own `sources` M2M and the inbuilt flow binds that stage without populating it | operator: "I cannot see any way to log in with google" |
| `state: update` patches an existing object | Not a state. `BlueprintEntryDesiredState` is exactly `{absent, present, created, must_created}`, and an invalid state rejects the **whole** blueprint, so a correct entry above it stopped applying too | `POST /api/v3/flows/executor/default-authentication-flow/` returning `sources: []` |

The last one is the only failure here that was checkable from the file alone, and it is now rejected by
`scripts/setup-google-blueprint.sh` before anything reaches a cluster. The public flow-executor endpoint
is worth remembering as a check: it returns the Identification stage's own source list, so it proves the
button exists without anyone clicking it and without credentials.

### A failing blueprint logs its own inputs

The importer's `Entry invalid` line dumps the whole entry, **attrs included**. For a blueprint that
carries a credential — which authentik's blueprint Secrets must, since there is no other way to get one
in — that means **a blueprint that fails on startup writes its credentials into container logs**, where
they outlive the pod and go wherever the log pipeline goes.

This cuts directly against the habit this section recommends. Both are still right, in order:

1. Render locally, then `ak apply_blueprint` **in the foreground** on the mounted file and read the
   output. Silent hourly discovery is how four bad blueprints passed unnoticed.
2. Redact before the output goes anywhere durable:
   `... 2>&1 | sed -E 's/GOCSPX-[A-Za-z0-9_-]+/REDACTED/g'`
   Dropping that pipe is how a live Google secret ended up in a terminal and a chat transcript.

### Proven working

```
GET /source/oauth/login/google/ -> 302 https://accounts.google.com/o/oauth2/auth
  client_id     343910733311-…apps.googleusercontent.com
  redirect_uri  https://auth.titan.arrieta.eu/source/oauth/callback/google/
  scope         email profile
```

## 12. `prompt=login` — the mobile login that fails on a flow with no bindings

Landed 2026-10-23 (`apply/10-secrets/authentik-google-blueprint.yaml`, entry `default-source-authentication`).

**Symptom.** A mobile or desktop client reaches authentik, Google accepts the password, and the user is
told the flow does not apply to them. **Web login is completely fine the whole time**, which is what makes
this look like the client's problem or the relying app's problem rather than authentik's.

### The mechanism

OpenCloud's Android client puts `prompt=login` into the authorization URL and there is no setting for it
(`OAuthUtils.kt` appends `QUERY_PARAMETER_PROMPT`; the desktop client sends its own supported prompt
values at `oauth.cpp:457`). `prompt=login` means *run the login flow even though this user already has a
session* — and authentik obliges, re-entering the flow with the session intact.

The flow it re-enters is the **source** flow, the one named by the source's own `authentication_flow` —
`default-source-authentication` here, not `default-authentication-flow`. That one ships with
`authentication: require_unauthenticated`, so `authentik/flows/planner.py:218` raises
`FlowNonApplicableException`. The web client never sends `prompt=login`, so it never re-enters and never
meets the check. Same provider, same application, same redirect set: one query parameter is the entire
difference, which is why "web works" is a misleading signal here rather than a reassuring one.

### Where the log is, and why it hides from every obvious filter

```
logger:  authentik.core.sources.flow_manager
event:   Flow non applicable
source:  <OAuthSource: google>
```

**There is no flow slug in that line.** Not in the message, not in a field. Filtering authentik's logs on
`flow` or `slug` — the obvious thing to do when the error says "this flow" — hides the one record that
explains the failure. The two fields that identify it are `logger` and `source`, and neither is what you
would think to print:

```sh
# jq is not preinstalled on titan's workspaces: nix-shell -p jq --run '<the command below>'
kubectl --context titan -n auth logs deploy/authentik-server --since=10m \
  | jq -r 'select(.event | test("non applicable")) | [.logger, (.source | tostring), .event] | @tsv'
```

Print those three fields first. It is the whole diagnosis in one line and it cost about an hour to find
because every narrower query looked reasonable.

### What was audited while looking in the wrong place

| checked | result | why it misled |
|---|---|---|
| `default-authentication-flow` → `authentication` | `none` | **correct** — that flow is genuinely innocent |
| its Policy / Group / User bindings | empty | **correct** — nothing binds it, and correctly so |
| OpenCloud autoprovisioning, LDAP `Result Code 49` | unrelated | the failure happens upstream of OpenCloud entirely |

Both checks were right and neither was the answer. A flow whose bindings are empty and whose
authentication is `none` is exactly what a healthy flow looks like, so the audit confirmed the wrong
thing confidently. The lesson is not "check more flows" — it is that **a social source has its own flow**
and it is reached only on the paths that re-enter login.

### The fix, and its blast radius

```yaml
  - model: authentik_flows.flow
    identifiers:
      slug: default-source-authentication
    state: present
    attrs:
      authentication: none
```

`none` is the API value for the UI's **Any users** (`FlowAuthenticationRequirement.NONE`,
`authentik/flows/models.py:37`). Blast radius is every social login that starts from an existing
session — Google is the only source here and that path was simply broken, so this removes a failure
rather than loosening a control: the flow still authenticates only the user the Google identity is
already linked to (`user_matching_mode: email_link`, no `enrollment_flow`), it no longer refuses to run.

The alternative not taken: a dedicated flow bound to this source's `authentication_flow` would change
nothing else at all, but it needs the stages `default-source-authentication` already has and those are
not enumerable from this repo. A flow with no stages raises `EmptyFlowException` — a worse outage than
the one being fixed.

### After an authentik upgrade, check this field first

System defaults are re-created by authentik's own blueprints, so `authentication` can come back as
`require_unauthenticated` on upgrade. Ours re-asserts on the next blueprint apply, but if mobile logins
break after an upgrade and nothing in the diff explains it, this is the first field to look at.

Reading it without the UI — the sidebar group is **Flows & Stages** → **Flows**, and both flows have
designation `authentication`, which is what makes them easy to confuse:

```sh
kubectl --context titan -n auth exec deploy/authentik-server -- python -c "import django,os;os.environ['DJANGO_SETTINGS_MODULE']='authentik.root.settings';django.setup();from authentik.flows.models import Flow;print(Flow.objects.get(slug='default-source-authentication').authentication)"
```

### Proven

After the field change, Android logged in. In the window: 0 `Flow non applicable` events, one successful
`/source/oauth/callback/google/`, no OpenCloud autoprovisioning failure.
