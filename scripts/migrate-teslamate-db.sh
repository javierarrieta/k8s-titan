#!/usr/bin/env bash
# Dump TeslaMate's database from k8s-techdelivery's bare Postgres and restore it into titan's CNPG
# cluster, so the trip history survives the move to the Fleet API.
#
# RUN IT, DON'T READ IT INTO A SHELL (the operator's login shell is fish; see setup-coder-secrets.sh).
#
# Needs an ADMIN context on both clusters, and says so rather than hanging: the read-only k8s-reader
# identity is Forbidden on pods/exec in `databases` on both (verified with `auth can-i`, which is why
# the guard below checks permission before touching anything instead of letting kubectl fail
# mid-dump with a half-written file on disk).
#
# --no-owner --no-privileges on the restore is not cosmetic. The dump names techdelivery's roles,
# which do not exist here, and CNPG owns role creation through the DatabaseRole in git — restoring
# with ownership intact fails on the first ALTER OWNER, after the data is already in.
#
# Idempotent by refusal: it aborts if the target already has tables. A second run against a live
# TeslaMate would double-insert history, and a duplicated trip is much harder to notice than a
# restore that failed.
set -euo pipefail

SRC=${SRC_CONTEXT:?SRC_CONTEXT=<admin context for k8s-techdelivery>}
DST=${DST_CONTEXT:?DST_CONTEXT=<admin context for k8s-titan>}
NS=databases
# One double-quoted string spanning lines, not several strings joined with backslashes: a backslash
# *outside* the quotes makes the following quoted word a separate argument to the assignment, and bash
# then tries to execute it — a confusing `command not found` at line 24 instead of a SQL error.
# (That is exactly what the first version did, and `bash -n` plus a guard test caught it.)
# TeslaMate 4.3.0 has no `trips` and no `locations` table (verified against the live schema during the
# 2026-10-17 migration: cars, addresses, car_settings, charges, charging_processes, drives, geofences,
# import_*, positions, schema_migrations, settings, states, updates, plus private.tokens). Asking for
# a table that is not there makes the count query fail rather than report, so the real set is used.
COUNTS="select
  (select count(*) from cars)      cars,
  (select count(*) from drives)    drives,
  (select count(*) from charges)   charges,
  (select count(*) from addresses) addresses,
  (select count(*) from positions) positions,
  (select count(*) from geofences) geofences"

for tool in kubectl; do command -v "$tool" >/dev/null || { echo "FAIL: $tool not on PATH"; exit 1; } done

# Check both permissions up front. Without this the failure mode is a truncated dump that looks like a
# successful one because the pipeline's exit status came from the last stage.
for pair in "source:$SRC" "target:$DST"; do
  role=${pair%%:*}; ctx=${pair#*:}
  if ! kubectl --context "$ctx" auth can-i create pods/exec -n "$NS" >/dev/null 2>&1; then
    echo "FAIL: the $role context '$ctx' cannot exec into pods in namespace '$NS'."
    echo "That is what the read-only k8s-reader identity gets: Forbidden. Re-run with an admin"
    echo "context, e.g. SRC_CONTEXT=<admin techdelivery> DST_CONTEXT=<admin titan> $0"
    exit 1
  fi
done

WORK=$(mktemp -d)
DUMP="$WORK/teslamate.dump"
trap 'rm -rf "$WORK"' EXIT

echo "== source: $SRC"
src_pod=$(kubectl --context "$SRC" -n "$NS" get pod -l app=postgres \
  -o jsonpath='{.items[0].metadata.name}')
echo "   pod $src_pod"
echo "   before:"
kubectl --context "$SRC" -n "$NS" exec "$src_pod" -c postgres -- \
  psql -U postgres -d teslamate -tAc "$COUNTS" | sed 's/^/     /'

echo "   dumping (custom format, compressed)"
kubectl --context "$SRC" -n "$NS" exec "$src_pod" -c postgres -- \
  pg_dump -Fc -d teslamate -U postgres > "$DUMP"
echo "   $(wc -c < "$DUMP") bytes"

echo "== target: $DST"
existing=$(kubectl --context "$DST" -n "$NS" exec postgres-1 -c postgres -- \
  psql -U postgres -d teslamate -tAc "select count(*) from pg_tables where schemaname='public'")
if [ "$existing" != "0" ]; then
  echo "FAIL: target database already has $existing tables. Refusing to double-insert history."
  echo "If the target really is wrong and you mean to replace it, drop and recreate it through the"
  echo "CNPG Database in git, then re-run — not by truncating tables here."
  exit 1
fi

echo "   restoring as teslamate into teslamate"
kubectl --context "$DST" -n "$NS" exec -i postgres-1 -c postgres -- \
  pg_restore -U teslamate -d teslamate --no-owner --no-privileges < "$DUMP"

echo "   after:"
kubectl --context "$DST" -n "$NS" exec postgres-1 -c postgres -- \
  psql -U teslamate -d teslamate -tAc "$COUNTS" | sed 's/^/     /'

cat <<'EOF'

Now check the two blocks above line by line. Identical counts are the proof; a restore that "finished"
with fewer rows is a partial migration, and TeslaMate will not complain about it — it will just have
quietly less history than you had.

Then start TeslaMate (Task 8) and confirm the UI agrees with the database.
EOF
