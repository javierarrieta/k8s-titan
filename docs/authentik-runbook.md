# titan runbook — Postgres backups, restore drill, authentik

Scope: the shared CloudNativePG `Cluster` in `databases` and the authentik install that
depends on it. Written against operator 1.30.1 / Postgres 18.6 on titan.

**Proven vs pending.** The backup and restore sections below describe a path that was
exercised on the live cluster and is current as of this writing. The authentik sections
describe a system that is specified but not yet deployed — Tasks 7 and 8 are open — so
they are marked and must be verified, not trusted, until authentik is live.

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
round trip. Point it at authentik when authentik is live:

```bash
# once authentik is live - assert users came back:
CHECK_DB=authentik CHECK_SQL='select count(*) from core_user' ./scripts/restore-drill.sh
```

Point-in-time is supported by the same script and is the drill worth doing second,
because PITR is what an incident actually needs:

```bash
TARGET_TIME='2026-10-05T09:00:00+00:00' EXPECT=absent SEED=0 ./scripts/restore-drill.sh
```

That restores to before the nonce existed and asserts it is **absent** — proving
`recoveryTarget` is honoured rather than ignored, which a latest-recovery drill cannot
tell you.

### Recorded output from the first successful run

> PASTE HERE. Definition of done for this section is that real output from
> `./scripts/restore-drill.sh` on titan sits in this block. Until it does, this document
> describes a restore that has only ever been written, and the etcd snapshot in
> `nixos-configurations` failed silently for four nights for exactly that reason.

```
(not yet run on the live cluster)
```

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

*Pending Task 8; recorded now so it is not discovered the hard way.*

`AUTHENTIK_SECRET_KEY` signs session cookies **and derives unique user IDs**. Changing it
invalidates every session and changes how user IDs derive. The chart's own comment says
do not change it after first install.

It lives in `apply/10-secrets/authentik-secrets.*.sops.yaml`, and **the sops file is its
only backup** — there is no database copy of it. Losing it means losing authentik's
identity continuity, not just a secret. If it ever must change, that is a planned
migration with the user-ID implications worked out first, not an incident response.

The same file holds `AUTHENTIK_POSTGRESQL__PASSWORD`. `AUTHENTIK_BOOTSTRAP_PASSWORD` is
deliberately unused: it puts a plaintext password in a pod spec for no benefit, since the
first login is a human act anyway.

---

## 4. First admin

*Pending Task 8 — specified, not yet verified.*

Browser flow at `https://auth.titan.arrieta.eu/if/flow/initial-setup/` — **trailing
slash required**, `Not Found` without it. No admin password ever enters git.

---

## 5. Open decision carried forward

*Sub-project 3, so it is not re-derived from scratch next session.*

How titan's services learn about their users: authentik **blueprint export** (config as
code, declarative, the mechanism the spec calls the right long-term answer) versus
**OAuth federation** (each service holds its own client secret and maps claims locally).
Deliberately deferred — adding blueprints before the import mechanism is chosen would be
speculative, and authentik config-as-code is out of scope for this slice (spec A10).
