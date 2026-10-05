# titan runbook — Postgres backups, restore drill, authentik

Scope: the shared CloudNativePG `Cluster` in `databases` and the authentik install that
depends on it. Written against operator 1.30.1 / Postgres 18.6 on titan.

**Proven vs pending.** Everything below describes a deployed system: the backup path, the
restore drill, point-in-time recovery, the CloudNativePG operator, the shared `Cluster`, and
authentik itself are all live on titan and were checked rather than assumed, and the first
admin exists (§4). What is not done: the **S3 backup key is still the exposed one** (§1), and
the restore drill has never been run against authentik's own tables (§2). Sections say which
of their claims were observed and which are reasoning.

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
`apply/50-apps/databases/`: `schedule` needs **six** cron fields (`"0 0 3 * * *"`),
because CNPG pins robfig/cron v1.2.0 where the optional field is day-of-week at the end,
so the familiar five-field form fires hourly; and `retentionPolicy` is a child of
`spec.backup`, not of `barmanObjectStore`.

### The backup credential is exposed — rotate it before trusting it

The IAM access key behind `s3-backup-secrets` (user `k8s-titan-pg-backups`) was pasted into
a chat transcript while the Secret was being authored, so that the Secret could be
sops-encrypted from it. The committed Secret is fine; the transcript is not, and the key has
not been swapped. Until it is, treat this credential as **exposed**, not as merely
unscheduled-for-rotation. The bucket policy is object-scoped to this one bucket, which caps
the blast radius at this bucket rather than the account — that limits the damage and does
not make the key safe.

Rotate create-then-delete, never delete-then-create:

1. Create a second access key for `k8s-titan-pg-backups` in IAM.
2. Re-sops `apply/10-secrets/s3-backup-secrets.yaml` with the new pair, `make check`, merge.
3. Prove archiving is still advancing — a fresh segment under `postgres/wals/`, or a clean
   `./scripts/restore-drill.sh`. CNPG does not reliably pick up a changed backup Secret on
   its own (cloudnative-pg#4914); if WAL stops shipping, roll the instance pods.
4. Only after step 3 passes, delete the old key.

Deleting first leaves the cluster archiving to a bucket it can no longer write to, and the
failure is silent — see the next subsection.

### What "healthy" does not mean

`ContinuousArchiving: True` is not evidence that WAL is reaching the bucket. Before the
backup configuration existed, that condition was `True` on a cluster that was archiving
nothing — with no barman destination the archiver skips and still reports success. Trust
the object listing:

```bash
aws s3 ls s3://k8s-titan-pg-562256260016-eu-west-1-an --region eu-west-1 --recursive
```

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
DELETE=1 ./scripts/restore-drill.sh 2>&1 | tee /tmp/restore-drill-$(date +%F).log
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
SEED=0 CHECK_DB=authentik \
  CHECK_SQL="select username from core_user where username='akadmin'" \
  EXPECT=akadmin ./scripts/restore-drill.sh
```

**Do not write that assertion as `select count(*) from core_user`.** The script's bare
assertion is "the query returned at least one row", and `count(*)` always returns exactly
one row — holding `0`. Verified against the script with a stub `kubectl` that prints what
real `psql` prints:

```
PASS: select count(*) from core_user returned 1 row(s): 0
```

That is a restore drill reporting success on a database with no users in it. The form above
cannot do that: no `akadmin` row means no rows, and the drill says
`FAIL: expected 'akadmin', got ''`. `SEED=0` because seeding a nonce would overwrite
`EXPECT` with the nonce; the two assertion styles do not mix.

Until the first admin existed this command failed, and that was the correct answer — it was
asserting something genuinely not true yet. It is the assertion to run now. It has **not**
been re-run since: both recorded runs below predate authentik entirely, so the
authentik-shaped drill is still owed a live pass.

Point-in-time is supported by the same script and is the drill worth doing second,
because PITR is what an incident actually needs:

```bash
TARGET_TIME='2026-10-05T09:00:00+00:00' EXPECT=absent SEED=0 ./scripts/restore-drill.sh
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
tracked as forward debt in `apply/50-apps/databases/postgres.yaml`; it is not a drive-by
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

Each run leaves a `Backup` CR in `databases` (three after the runs above) and a real base
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
(§5) — but a real round trip through the login page is the half that exercises a session
cookie, and it is worth walking once deliberately rather than discovering on a phone.

---

## 5. What the read-only identity can and cannot prove

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

## 6. Open decision carried forward

*Sub-project 3, so it is not re-derived from scratch next session.*

How titan's services learn about their users: authentik **blueprint export** (config as
code, declarative, the mechanism the spec calls the right long-term answer) versus
**OAuth federation** (each service holds its own client secret and maps claims locally).
Deliberately deferred — adding blueprints before the import mechanism is chosen would be
speculative, and authentik config-as-code is out of scope for this slice (spec A10).
