#!/usr/bin/env bash
# Restore drill for titan's CloudNativePG Postgres. See docs/authentik-runbook.md.
#
# CNPG never restores over a running cluster: bootstrap.recovery builds a NEW cluster
# from a base backup and replays WAL. So this stands a scratch cluster beside the live
# one. The live cluster is never written to, except by the optional seed step below.
#
# Needs an admin kubeconfig. The read-only k8s-reader identity cannot run this and must
# not be able to; preflight checks that rather than failing obscurely later.
#
# The scratch cluster is created ad hoc and never committed, so Flux neither owns nor
# prunes it. Committing it would put a second PVC request in git and invite someone to
# "fix" the duplication later.
#
# WHY THE ASSERTION IS A PARAMETER. The plan hard-coded `select count(*) from core_user`,
# which requires authentik to exist - so the drill could only ever be run after Task 8,
# which is the wrong order: the cheapest moment to drill a restore is while the database
# is empty and nothing can be lost. Default here is a nonce the seed step writes itself,
# so the drill proves a value survived the round trip through S3 rather than proving an
# empty database restored.
#
# The count(*) form is a trap, and the plan's original line had it. With no EXPECT set the
# assertion below is "the query returned at least one row", and count(*) always returns
# exactly one row - holding 0. So it passes on a database with no users. Point it at a named
# row instead, and pin EXPECT:
#   SEED=0 CHECK_DB=authentik \
#     CHECK_SQL="select username from authentik_core_user where username='akadmin'" EXPECT=akadmin
# authentik_core_user, not core_user: Django's default table is <app_label>_<model> and
# authentik's core app label is authentik_core. SEED=0 because seeding overwrites EXPECT with
# the nonce; the two styles do not mix. Worked example in docs/authentik-runbook.md §2.
#
# WHY THE RECOVERY SHAPE LOOKS LIKE THIS. The plan used
# bootstrap.recovery.barmanObjectStore, which does not exist in the 1.30.1 CRD -
# bootstrap.recovery takes backup|source|recoveryTarget|database|owner|secret|
# volumeSnapshots. The store config goes in an externalClusters[] entry whose name must
# equal the source cluster's name, because that name is also the folder under the bucket.
# Verified against the vendored CRD and against upstream's
# docs/src/samples/cluster-restore-external-cluster.yaml.
set -euo pipefail

NS=${NS:-databases}
SRC=${SRC:-postgres}
DRILL=${DRILL:-postgres-drill}
IMAGE=${IMAGE:-ghcr.io/cloudnative-pg/postgresql:18.6}
STORAGE_CLASS=${STORAGE_CLASS:-local-path}
STORAGE_SIZE=${STORAGE_SIZE:-10Gi}
BUCKET=${BUCKET:-k8s-titan-pg-562256260016-eu-west-1-an}
BACKUP_SECRET=${BACKUP_SECRET:-s3-backup-secrets}

# The assertion. CHECK_SQL must return a single scalar.
CHECK_DB=${CHECK_DB:-drill}
CHECK_SQL=${CHECK_SQL:-select nonce from restore_drill_marker}
# "" = require at least one row. "absent" = require zero rows (the PITR case).
# Anything else = require exactly that value.
EXPECT=${EXPECT:-}

SEED=${SEED:-1}          # write a fresh nonce into the source before backing up
TARGET_TIME=${TARGET_TIME:-}   # ISO8601 UTC for a point-in-time drill, empty = latest
WAIT=${WAIT:-20m}
DELETE=${DELETE:-1}

# Object names must be lowercase RFC 1123. `date +%Y%m%dT%H%M%SZ` emits an uppercase T and
# Z, and the API server rejects the Backup with "a lowercase RFC 1123 subdomain must
# consist of..." - which is exactly the kind of thing a stub harness cannot catch, since
# it is validation the API server does. Found on the first live run.
NOW=$(date -u +%Y%m%d%H%M%S)
NONCE="drill-${NOW}-$$"
BACKUP="drill-${NOW}"

CREATED=0

say() { printf '%s\n' "$*"; }

cleanup() {
  if [ "$DELETE" = "1" ]; then
    kubectl -n "$NS" delete cluster "$DRILL" --ignore-not-found >/dev/null 2>&1 || true
    # The seeded database is drill residue, not data. The Backup CR is deliberately
    # left behind: whether deleting a Backup CR also removes its object-store data is
    # not documented upstream (cloudnative-pg#2328 asks for exactly that and does not
    # get it), so this script will not be the one to find out.
    if [ "$SEED" = "1" ]; then
      kubectl -n "$NS" exec "$SRC-1" -c postgres -- \
        psql -U postgres -Atc 'drop database if exists drill' >/dev/null 2>&1 || true
    fi
    if [ "$CREATED" = "1" ]; then
      say "cleaned up scratch cluster $DRILL"
    fi
    say "(Backup $BACKUP left in $NS as the record)"
  else
    say "DELETE=0: leaving $DRILL and the seeded drill database in place"
  fi
}
trap cleanup EXIT
# No silent exits. `set -e` alone can abort between two `say` lines with no explanation at
# all - that is how the assertion bug above presented - so any abort names itself first.
trap 'rc=$?; [ "$rc" -ne 0 ] && say "FAIL: drill aborted (exit $rc) at line $LINENO"' ERR

say "== preflight"
command -v kubectl >/dev/null 2>&1 || { say "FAIL: kubectl not on PATH"; exit 1; }
if [ "$(kubectl auth can-i create "clusters.postgresql.cnpg.io" -n "$NS" 2>/dev/null)" != "yes" ]; then
  say "FAIL: this identity cannot create Clusters in $NS. This drill needs an admin"
  say "      kubeconfig; the read-only k8s-reader identity is not expected to pass."
  exit 1
fi
# "not Completed" is not a backup. Fail here rather than 15 minutes into a recovery
# that was never going to find a base backup. Note the lowercase: CNPG writes
# status.phase as "completed", and grepping for a capital C never matches anything.
phases=$(kubectl -n "$NS" get backup -o jsonpath='{range .items[*]}{.metadata.name}{" "}{.status.phase}{"\n"}{end}' 2>/dev/null || true)
if ! printf '%s\n' "$phases" | grep -q '[Cc]ompleted'; then
  say "FAIL: no completed Backup in $NS. Run:"
  say "  kubectl -n $NS apply -f - <<EOF"
  say "  apiVersion: postgresql.cnpg.io/v1"
  say "  kind: Backup"
  say "  metadata: {name: manual, namespace: $NS}"
  say "  spec: {method: barmanObjectStore, cluster: {name: $SRC}}"
  say "  EOF"
  exit 1
fi
printf '%s\n' "$phases" | sed 's/^/   existing backup: /'
# Ask for the one field, do not grep the serialised JSON: kubectl emits condition keys in
# alphabetical order, so status precedes type and a pattern like
# '"type":"Ready","status":"True"' never matches a cluster that is perfectly healthy. It
# warned on a Ready cluster on the first live run. A jsonpath filter cannot get that wrong.
ready=$(kubectl -n "$NS" get cluster "$SRC" \
  -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || true)
if [ "$ready" != "True" ]; then
  say "WARN: source cluster $SRC is not Ready (condition says '${ready:-absent}'); continuing anyway"
else
  say "   source $SRC Ready"
fi
say "   $(printf '%s\n' "$phases" | grep -c '[Cc]ompleted') completed backup(s) present"

if [ "$SEED" = "1" ]; then
  say "== seeding a nonce into $SRC so the restore has something to prove"
  # A separate database, so nothing of anyone else's is involved and the whole thing
  # drops cleanly at the end. Dropped first so a re-run after DELETE=0 starts clean
  # rather than dying on "database already exists". pg_switch_wal forces the WAL holding
  # the insert out to the archive now, rather than whenever the next segment fills.
  kubectl -n "$NS" exec "$SRC-1" -c postgres -- \
    psql -U postgres -Atc 'drop database if exists drill' >/dev/null
  kubectl -n "$NS" exec "$SRC-1" -c postgres -- \
    psql -U postgres -Atc 'create database drill' >/dev/null
  kubectl -n "$NS" exec "$SRC-1" -c postgres -- \
    psql -U postgres -d drill -Atc \
    'create table restore_drill_marker (nonce text, wrote_at timestamptz default now())' \
    >/dev/null
  kubectl -n "$NS" exec "$SRC-1" -c postgres -- \
    psql -U postgres -d drill -Atc "insert into restore_drill_marker (nonce) values ('$NONCE')"
  kubectl -n "$NS" exec "$SRC-1" -c postgres -- psql -U postgres -Atc 'select pg_switch_wal()' >/dev/null
  say "   seeded nonce: $NONCE"
  EXPECT="$NONCE"
fi

say "== taking Backup $BACKUP"
kubectl apply -f - <<EOF
apiVersion: postgresql.cnpg.io/v1
kind: Backup
metadata:
  name: $BACKUP
  namespace: $NS
spec:
  method: barmanObjectStore
  cluster:
    name: $SRC
EOF
kubectl -n "$NS" wait --for=jsonpath=.status.phase=completed "backup/$BACKUP" --timeout=15m
kubectl -n "$NS" get "backup/$BACKUP" -o jsonpath='   backupId={.status.backupId} beginWal={.status.beginWal}{"\n"}'

say "== standing up scratch cluster $DRILL from s3://$BUCKET/$SRC"
# externalClusters[].name must equal the source cluster name: it is also the folder the
# backups live under. See the header for why the store config is not under recovery.
if [ -n "$TARGET_TIME" ]; then
  say "   recovering to a point in time: $TARGET_TIME (exclusive)"
fi
kubectl apply -f - <<EOF
apiVersion: postgresql.cnpg.io/v1
kind: Cluster
metadata:
  name: $DRILL
  namespace: $NS
spec:
  instances: 1
  imageName: $IMAGE
  storage:
    size: $STORAGE_SIZE
    storageClass: $STORAGE_CLASS
  bootstrap:
    recovery:
      source: $SRC
$( [ -n "$TARGET_TIME" ] && printf '      recoveryTarget:\n        targetTime: %s\n        exclusive: true\n' "$TARGET_TIME" )
  externalClusters:
    - name: $SRC
      barmanObjectStore:
        destinationPath: s3://$BUCKET
        s3Credentials:
          accessKeyId:     {name: $BACKUP_SECRET, key: ACCESS_KEY_ID}
          secretAccessKey: {name: $BACKUP_SECRET, key: SECRET_ACCESS_KEY}
          region:          {name: $BACKUP_SECRET, key: AWS_REGION}
EOF
CREATED=1

say "== waiting for $DRILL to become Ready (recovery can take minutes)"
kubectl -n "$NS" wait --for=condition=Ready "cluster/$DRILL" --timeout="$WAIT"

say "== asserting the restore is real"
# CNPG's condition is Ready, not Healthy; --for=condition=Healthy never resolves and
# you find out only after the whole timeout has burned.
#
# `if !` instead of a bare assignment, and this is the bug it fixes: under `set -e` a
# non-zero psql aborts the script at the assignment, the EXIT trap deletes the scratch
# cluster behind it, and the drill prints its "== asserting" header and then nothing - no
# PASS, no FAIL, just a non-zero exit. Observed on titan 2026-10-05. The `2>&1` was always
# meant to bring psql's error text into the report; without the guard that text is captured
# into a variable that is never printed. A broken query must not look like a finished drill.
if ! got=$(kubectl -n "$NS" exec "$DRILL-1" -c postgres -- \
    psql -U postgres -d "$CHECK_DB" -Atc "$CHECK_SQL" 2>&1); then
  say "FAIL: the assertion query itself failed - this is NOT a value mismatch. psql said:"
  printf '%s\n' "$got" | sed 's/^/     /'
  say "      A missing table or database here means CHECK_DB/CHECK_SQL are wrong, not that"
  say "      the restore is broken. See docs/authentik-runbook.md §2."
  exit 1
fi
rows=$(printf '%s\n' "$got" | sed '/^$/d' | wc -l | tr -d ' ')

if [ "$EXPECT" = "absent" ]; then
  [ "$rows" -eq 0 ] || { say "FAIL: expected no rows at this target, got: $got"; exit 1; }
  say "PASS: $CHECK_SQL returned no rows at target ${TARGET_TIME:-latest}, as expected"
elif [ -n "$EXPECT" ]; then
  [ "$got" = "$EXPECT" ] || { say "FAIL: expected '$EXPECT', got '$got'"; exit 1; }
  say "PASS: restored value matches the expected value '$got'"
else
  # "At least one row" is the weakest of the three branches: a query that always returns a
  # row (count(*), show_settings, anything aggregate) passes here even when it reports
  # nothing worth finding. Prefer EXPECT=<value> against a query that returns no rows when
  # the thing you care about is absent.
  [ "$rows" -ge 1 ] || { say "FAIL: $CHECK_SQL returned no rows in the restored cluster"; exit 1; }
  say "PASS: $CHECK_SQL returned $rows row(s): $got"
fi

say "PASS: restore drill complete - $DRILL recovered from s3://$BUCKET/$SRC"
