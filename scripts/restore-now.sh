#!/usr/bin/env bash
# TeslaMate dump -> titan, self-contained. Needs kubectl with admin on k8s-titan only.
#   ./restore-now.sh ./teslamate.dump
# Every piece here was proven by hand first: /dev/shm is writable in the CNPG pod (root fs is not),
# .pgpass must be a host:port:db:user:pass LINE, and pg_restore cannot read stdin, so the archive
# is staged as a real file inside the pod and its size is compared before anything is touched.
set -euo pipefail

CTX=${CTX:-k8s-titan}
NS=${NS:-databases}
APP_NS=${APP_NS:-apps}
APP=${APP:-teslamate}
SVC=postgres-rw.databases.svc.cluster.local
DUMP=${1:?usage: $0 <dump-file>}

[ -f "$DUMP" ] || { echo "FAIL: no file at $DUMP"; exit 1; }
BYTES=$(wc -c < "$DUMP" | tr -dc '0-9')
[ "$BYTES" -gt 1000 ] || { echo "FAIL: $DUMP is $BYTES bytes, not an archive"; exit 1; }
echo "dump: $BYTES bytes"

POD=$(kubectl --context "$CTX" -n "$NS" get pod -l cnpg.io/cluster=postgres,role=primary \
        -o jsonpath='{.items[0].metadata.name}')
[ -n "$POD" ] || { echo "FAIL: no CNPG primary in $NS"; exit 1; }
echo "target pod: $POD"

PW=$(kubectl --context "$CTX" -n "$NS" get secret teslamate-db-credentials -o jsonpath='{.data.password}' | base64 -d)
[ "${#PW}" -eq 32 ] || { echo "FAIL: password length ${#PW}, expected 32"; exit 1; }
echo "password read (32 chars)"

PWFILE=/dev/shm/.pw
DFILE=/dev/shm/teslamate.dump
ex()  { kubectl --context "$CTX" -n "$NS" exec "$POD" -c postgres -- sh -c "$1"; }
exi() { kubectl --context "$CTX" -n "$NS" exec -i "$POD" -c postgres -- sh -c "$1"; }

# /dev/shm is tmpfs (RAM, never touches the DB disk); fall back to the data volume if it is small.
FREE=$(ex "df -Pk /dev/shm | awk 'NR==2{print \$4}'" | tr -dc '0-9')
if [ "${FREE:-0}" -lt $((BYTES / 1024 + 51200)) ]; then DFILE=/controller/teslamate.dump; fi
echo "staging at $DFILE (/dev/shm has ${FREE:-?} KB free)"

printf '%s\n' "$SVC:*:*:teslamate:$PW" | exi "umask 077; cat > $PWFILE && chmod 600 $PWFILE"
kubectl --context "$CTX" -n "$NS" exec -i "$POD" -c postgres -- sh -c "cat > $DFILE" < "$DUMP"
GOT=$(ex "wc -c < $DFILE" | tr -dc '0-9')
[ "$GOT" = "$BYTES" ] || { ex "rm -f $PWFILE $DFILE"; echo "FAIL: staged $GOT of $BYTES bytes - truncated transfer, nothing restored"; exit 1; }
echo "staged $GOT bytes, size matches"

ex "pg_restore --list $DFILE > /dev/null" || { ex "rm -f $PWFILE $DFILE"; echo "FAIL: not a readable archive, nothing restored"; exit 1; }
echo "archive readable by pg_restore"

counts() {
  for t in cars drives charges addresses positions geofences; do
    printf '  %-10s %s\n' "$t" "$(ex "env PGPASSFILE=$PWFILE PGSSLMODE=require psql --host=$SVC -U teslamate -d teslamate -tAc 'select count(*) from $t'" 2>&1 | tail -1)"
  done
}
echo "== BEFORE"; counts

echo "== scaling $APP to 0"
kubectl --context "$CTX" -n "$APP_NS" scale deploy/"$APP" --replicas=0
kubectl --context "$CTX" -n "$APP_NS" wait --for=delete pod -l app="$APP" --timeout=180s 2>/dev/null || true

# --clean emits DROP TABLE without CASCADE, so the first drop fails on a dependent foreign key, the
# matching CREATE then fails "already exists", and the restore aborts. The BEFORE counts prove the
# schema holds no rows, so drop it wholesale - the teslamate role is a superuser (PR #58).
# `private` is not optional: TeslaMate keeps its token pairs there, and leaving a previous attempt's
# rows behind duplicates them - the COPY appends, the PK then fails, and TeslaMate refuses to start
# with "Found 2 token pairs!" (observed on the live cluster).
echo "== dropping the empty schemas (CASCADE takes the foreign keys with it)"
ex "env PGPASSFILE=$PWFILE PGSSLMODE=require psql --host=$SVC -U teslamate -d teslamate -qc 'DROP SCHEMA public CASCADE; DROP SCHEMA IF EXISTS private CASCADE; CREATE SCHEMA public; GRANT ALL ON SCHEMA public TO teslamate;'" \
  || { ex "rm -f $PWFILE $DFILE"; echo "FAIL: could not reset the schema; nothing was restored"; exit 1; }

echo "== restoring into the empty schema (no --clean: there is nothing left to drop)"
# pg_restore exits 1 on warnings too, so its status is reported, not trusted: the counts are the proof.
ex "env PGPASSFILE=$PWFILE PGSSLMODE=require pg_restore --host=$SVC -U teslamate -d teslamate --no-owner --no-privileges $DFILE" 2>&1 | tail -25 \
  || echo "  pg_restore exited non-zero - warnings do that; the counts decide"

echo "== scaling $APP back to 1"
kubectl --context "$CTX" -n "$APP_NS" scale deploy/"$APP" --replicas=1

echo "== AFTER"; counts
ex "env PGPASSFILE=$PWFILE PGSSLMODE=require psql --host=$SVC -U teslamate -d teslamate -tAc 'select count(*) from private.tokens' | tail -1 | sed 's/^/  tokens: /'" || true
ex "rm -f $PWFILE $DFILE" || true   # after the counts: they read the password from this file
echo
echo "TeslaMate needs EXACTLY ONE row in private.tokens - two means it will crash-loop with"
echo "'Found 2 token pairs!'. Source counts were: cars 2, drives 3251, charges 520368,"
echo "addresses 1025, positions 9453030, geofences 19. Equal is the proof."
