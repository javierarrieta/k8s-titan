#!/usr/bin/env bash
# Move TeslaMate's database from k8s-techdelivery to titan's CNPG cluster.
#
#   ./import-teslamate.sh dump    [<file>]     # only: pull the dump to the laptop
#   ./import-teslamate.sh restore <file>       # only: import a dump you already have
#   ./import-teslamate.sh all     [<file>]     # both
#
# Needs on the laptop: kubectl with an ADMIN context on both clusters. Nothing else.
# pg_dump and pg_restore run INSIDE the pods, so no postgres client is installed here;
# if your laptop has no kubectl either:  nix-shell -p kubectl --run './import-teslamate.sh all'
#
# Why it is shaped this way:
#   * The password is read from the live Secret in the cluster and handed to the pod through
#     stdin into ~/.pgpass-style file (chmod 600, deleted on exit). It never appears in an
#     argument list, a log, or on your screen, and sops is never needed on the laptop.
#   * The dump goes through a real file, not a pipe between two kubectl execs: a broken pipe
#     mid-stream produces a truncated archive that restores partially and looks fine.
#   * The archive is validated with pg_restore --list BEFORE anything is dropped.
#   * TeslaMate is scaled to 0 for the import and back afterwards, even if the import fails.
set -euo pipefail

SRC_CTX=${SRC_CTX:-k8s-techdelivery}
DST_CTX=${DST_CTX:-titan}
NS=${NS:-databases}
DB_NAME=${DB_NAME:-teslamate}
DB_USER=${DB_USER:-teslamate}
DST_SECRET=${DST_SECRET:-teslamate-db-credentials}   # in $NS; apps/teslamate-secrets holds the same value
DST_APP_NS=${DST_APP_NS:-apps}
DST_APP=${DST_APP:-teslamate}
DST_SVC=${DST_SVC:-postgres-rw.databases.svc.cluster.local}
KEEP_DUMP=${KEEP_DUMP:-1}          # 1 leaves the dump file in place instead of deleting it

die() { printf '\nFAIL: %s\n' "$*" >&2; exit 1; }
say() { printf '\n== %s\n' "$*"; }

MODE=${1:-all}
DUMP=${2:-./teslamate.dump}
case "$MODE" in dump|restore|all) ;; *) die "usage: $0 {dump|restore|all} [<dump-file>]" ;; esac

command -v kubectl >/dev/null || die "kubectl not on PATH (nix-shell -p kubectl --run '...')"

# ---- counts, used both as the before-picture and as the proof -------------------------------
COUNT_TABLES="cars drives trips charges addresses positions geofences"
run_counts() {  # $1 = "src"|"dst"; one query per table so a missing one costs a line, not the run
  local side=$1
  for t in $COUNT_TABLES; do
    if [ "$side" = src ]; then
      n=$(kubectl --context "$SRC_CTX" -n "$NS" exec "$SRC_POD" -c postgres -- \
            psql -U postgres -d "$DB_NAME" -tAc "select count(*) from $t" 2>/dev/null | tr -d ' ') \
        && printf '  %-10s %s\n' "$t" "${n:-?}" || printf '  %-10s (no such table)\n' "$t"
    else
      n=$(dst_psql -tAc "select count(*) from $t" 2>/dev/null | tr -d ' ') \
        && printf '  %-10s %s\n' "$t" "${n:-?}" || printf '  %-10s (no such table)\n' "$t"
    fi
  done
}

# ---- source pod (only needed when a dump is actually happening) ---------------------------------
SRC_POD=$(kubectl --context "$SRC_CTX" -n "$NS" get pod -l app=postgres \
            -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
if [ -z "$SRC_POD" ]; then
  case "$MODE" in dump|all) die "no pod with label app=postgres in $SRC_CTX/$NS. Is SRC_CTX right? (contexts: $(kubectl config get-contexts -o name | tr '\n' ' '))" ;; esac
fi

# ---- target primary pod -----------------------------------------------------------------------
DST_POD=$(kubectl --context "$DST_CTX" -n "$NS" get pod -l cnpg.io/cluster=postgres,role=primary \
            -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
[ -n "$DST_POD" ] || die "no CNPG primary in $DST_CTX/$NS (label cnpg.io/cluster=postgres,role=primary)"

# ---- the target password, from the cluster (read only when a restore is actually happening) -----
DBPASS=""
read_dbpass() {  # $1 = "password"|"DATABASE_PASS"; tried in order, never printed
  local v
  v=$(kubectl --context "$DST_CTX" -n "$NS" get secret "$DST_SECRET" \
        -o jsonpath='{.data.password}' 2>/dev/null | base64 -d 2>/dev/null || true)
  [ -n "$v" ] || v=$(kubectl --context "$DST_CTX" -n "$DST_APP_NS" get secret teslamate-secrets \
        -o jsonpath='{.data.DATABASE_PASS}' 2>/dev/null | base64 -d 2>/dev/null || true)
  [ -n "$v" ] || die "could not read the password from $NS/$DST_SECRET (key 'password') or $DST_APP_NS/teslamate-secrets (key 'DATABASE_PASS'). Keys present: $(kubectl --context "$DST_CTX" -n "$NS" get secret "$DST_SECRET" -o jsonpath='{.data}' 2>/dev/null | tr ',' '\n' | cut -d: -f1 | tr '\n' ' ')"
  DBPASS=$v
}

# ---- how we talk to the target from inside its own pod -----------------------------------------
# CNPG enables TLS, but the exact pg_hba/sslmode combination is not something to guess at: probe
# sslmode=require then disable, and remember which worked. The password travels in a 0600 file
# written over stdin, never in argv.
# CNPG pods run with readOnlyRootFilesystem, so /tmp is NOT writable there (observed: "cannot
# create /tmp/.im-ts-pw: Read-only file system"). /dev/shm is a tmpfs mount that survives that and
# keeps the credential off the disk; the rest are fallbacks. Override with PW_FILE=/somewhere.
PW_FILE=${PW_FILE:-}
SSL_MODE=""
dst_exec() { kubectl --context "$DST_CTX" -n "$NS" exec -i "$DST_POD" -c postgres -- sh -c "$1"; }
dst_psql() {
  local q="" a
  for a in "$@"; do q="$q $(printf '%q' "$a")"; done   # SQL has spaces; $* would split it into argv
  dst_exec "env PGPASSFILE=$PW_FILE PGSSLMODE=$SSL_MODE PATH=\$PATH:/usr/local/bin:/usr/lib/postgresql/18/bin psql --host=$DST_SVC --username=$DB_USER --dbname=$DB_NAME -X$q"
}
probe_pw_dir() {
  [ -n "$PW_FILE" ] && return 0
  local cand
  for cand in /dev/shm/.im-ts-pw /controller/.im-ts-pw /controller/run/.im-ts-pw /tmp/.im-ts-pw; do
    if dst_exec "umask 077; : > $cand && chmod 600 $cand && rm -f $cand" >/dev/null 2>&1; then
      PW_FILE=$cand; say "credential file will live at $PW_FILE (mode 0600, removed on exit)"; return 0
    fi
  done
  die "no writable directory inside $DST_POD (tried /dev/shm, /controller, /controller/run, /tmp). Pass PW_FILE=/somewhere/writable."
}
probe_ssl() {
  for mode in require disable; do
    if dst_exec "env PGPASSFILE=$PW_FILE PGSSLMODE=$mode PATH=\$PATH:/usr/local/bin:/usr/lib/postgresql/18/bin psql --host=$DST_SVC --username=$DB_USER --dbname=$DB_NAME -X -tAc 'select 1'" >/dev/null 2>&1; then
      SSL_MODE=$mode; say "target reachable over $DST_SVC (sslmode=$mode)"; return 0
    fi
  done
  die "cannot connect to $DST_SVC as $DB_USER from inside $DST_POD. Check the password and that $DB_NAME exists (CNPG Database resource)."
}
install_pw() {
  # .pgpass is line-oriented: host:port:database:username:password. Writing the bare password (the
  # first version did exactly that) makes psql ignore the file and try to prompt, which in a
  # non-interactive exec surfaces as the misleading "fe_sendauth: no password supplied".
  # ':' and backslash inside the password must be escaped; the generated one is hex, but do not
  # assume that forever.
  local esc
  esc=$(printf '%s' "$DBPASS" | sed 's/[\\:]/\\&/g')
  printf '%s:*:*:%s:%s\n' "$DST_SVC" "$DB_USER" "$esc" \
    | dst_exec "umask 077; cat > $PW_FILE; chmod 600 $PW_FILE; test -s $PW_FILE && grep -q ':' $PW_FILE" \
    || die "could not write $PW_FILE inside $DST_POD"
}
remove_pw() { dst_exec "rm -f $PW_FILE" 2>/dev/null || true; }

# ---- staging the dump inside the pod ------------------------------------------------------------
# pg_restore has NO stdin support: a `-` argument is taken as a literal filename and fails with
# "could not open input file \"-\"" (observed). So the archive is streamed into a real file inside
# the pod first, and its byte count is compared afterwards - a truncated transfer is the failure
# mode that would otherwise surface as a half-restored database.
DUMP_FILE=""
probe_dump_dir() {  # $1 = bytes needed
  local need=$1 cand free
  for cand in /dev/shm /controller /tmp; do
    free=$(dst_exec "df -Pk $cand 2>/dev/null | awk 'NR==2{print \$4}'" 2>/dev/null | tr -dc '0-9')
    [ -n "$free" ] || continue
    [ "$free" -gt "$((need / 1024 + 51200))" ] || continue
    dst_exec "umask 077; : > $cand/.im-ts-probe && rm -f $cand/.im-ts-probe" 2>/dev/null || continue
    DUMP_FILE=$cand/.im-ts-dump
    say "staging the dump at $DUMP_FILE ($((free / 1024)) MB free there)"
    return 0
  done
  die "no writable directory inside $DST_POD with room for the dump (tried /dev/shm, /controller, /tmp). Free space seen: $(dst_exec 'df -Pk /dev/shm /controller /tmp 2>&1' | tr '\n' ' ')"
}
stage_dump() {  # $1 = local byte count
  kubectl --context "$DST_CTX" -n "$NS" exec -i "$DST_POD" -c postgres -- \
    sh -c "cat > $DUMP_FILE" < "$DUMP" || die "could not stream the dump into $DST_POD:$DUMP_FILE"
  local got; got=$(dst_exec "wc -c < $DUMP_FILE" | tr -dc '0-9')
  [ "$got" = "$1" ] || die "staged dump is $got bytes, expected $1 - the transfer was truncated, nothing has been restored yet"
  echo "  staged $got bytes and the size matches"
}
remove_dump() { [ -n "$DUMP_FILE" ] && dst_exec "rm -f $DUMP_FILE" 2>/dev/null || true; }

# ---- teslamate up/down -------------------------------------------------------------------------
PREV_REPLICAS=""
scale_app() {  # $1 = replicas
  [ -n "$PREV_REPLICAS" ] || return 0
  kubectl --context "$DST_CTX" -n "$DST_APP_NS" scale deploy/"$DST_APP" --replicas="$1" >/dev/null
}
stop_app() {
  PREV_REPLICAS=$(kubectl --context "$DST_CTX" -n "$DST_APP_NS" get deploy "$DST_APP" \
                    -o jsonpath='{.spec.replicas}' 2>/dev/null || echo "")
  [ -n "$PREV_REPLICAS" ] || { say "no $DST_APP Deployment in $DST_APP_NS; nothing to stop"; return 0; }
  say "scaling $DST_APP to 0 (it races the import otherwise)"
  scale_app 0
  kubectl --context "$DST_CTX" -n "$DST_APP_NS" wait --for=delete pod -l app="$DST_APP" --timeout=180s 2>/dev/null || true
}
restore_app() {
  [ -n "$PREV_REPLICAS" ] && [ "$PREV_REPLICAS" != "0" ] || return 0
  say "scaling $DST_APP back to $PREV_REPLICAS"
  scale_app "$PREV_REPLICAS"
}

cleanup() { local rc=$?; remove_dump; remove_pw; restore_app; [ "$KEEP_DUMP" = 1 ] || rm -f "$DUMP"; exit $rc; }

# ================================================================================================
# dump
# ================================================================================================
do_dump() {
  say "source: $SRC_CTX/$NS pod $SRC_POD"
  say "row counts in the source"
  run_counts src
  say "dumping (custom format, compressed) -> $DUMP"
  kubectl --context "$SRC_CTX" -n "$NS" exec "$SRC_POD" -c postgres -- \
    pg_dump -Fc -d "$DB_NAME" -U postgres > "$DUMP" || die "pg_dump failed (nothing was written to the target)"
  local bytes; bytes=$(wc -c < "$DUMP" | tr -d ' ')
  [ "$bytes" -gt 1000 ] || die "dump is only $bytes bytes - that is not a real archive"
  say "wrote $bytes bytes to $DUMP"
}

# ================================================================================================
# restore
# ================================================================================================
do_restore() {
  [ -f "$DUMP" ] || die "no dump file at $DUMP (run: $0 dump $DUMP)"
  case "$DUMP" in -|/dev/stdin) die "pass a real file, not a pipe - pg_restore must seek" ;; esac
  local bytes; bytes=$(wc -c < "$DUMP" | tr -d ' ')
  [ "$bytes" -gt 1000 ] || die "$DUMP is only $bytes bytes - that is not a real archive"
  read_dbpass

  say "target: $DST_CTX/$NS pod $DST_POD (primary), database $DB_NAME as $DB_USER"
  probe_pw_dir
  install_pw
  probe_ssl
  trap cleanup EXIT

  say "validating the archive before touching anything"
  probe_dump_dir "$bytes"
  stage_dump "$bytes"
  dst_exec "pg_restore --list $DUMP_FILE >/dev/null" \
    || die "$DUMP is not a readable pg_dump custom archive ($bytes bytes). Nothing has been restored."
  echo "  archive OK ($bytes bytes, pg_restore can read every section)"

  say "row counts in the target BEFORE"
  run_counts dst
  existing=$(dst_psql -tAc "select count(*) from pg_tables where schemaname='public'" 2>/dev/null | tr -d ' ' || true)
  if [ "${existing:-0}" != "0" ] && [ "${ALLOW_NONEMPTY:-0}" != "1" ]; then
    die "the target already has ${existing} tables. TeslaMate's migrations created them, and --clean will drop them. If the counts above are all 0 that is exactly what is happening and it is safe: re-run with ALLOW_NONEMPTY=1. If they are NOT 0, stop - you would be overwriting real history."
  fi

  stop_app

  # --clean emits DROP TABLE without CASCADE, and TeslaMate's tables hold foreign keys into each
  # other: the first DROP fails ("HINT: Use DROP ... CASCADE"), the CREATE then fails "already
  # exists", and the restore aborts partway (observed on the live cluster). The BEFORE counts above
  # proved the schema is empty, so drop it wholesale - the teslamate role is a superuser.
  say "dropping the empty schema (CASCADE takes the foreign keys with it)"
  dst_psql -qc "DROP SCHEMA public CASCADE; CREATE SCHEMA public; GRANT ALL ON SCHEMA public TO $DB_USER;" \
    || die "could not reset the schema; nothing was restored"

  say "restoring into the empty schema (no --clean: nothing is left to drop)"
  # pg_restore exits 1 for warnings as well as errors, so its status is reported, not trusted:
  # the counts afterwards are the proof.
  if dst_exec "env PGPASSFILE=$PW_FILE PGSSLMODE=$SSL_MODE pg_restore --host=$DST_SVC --username=$DB_USER --dbname=$DB_NAME --no-owner --no-privileges $DUMP_FILE" 2>&1 | tail -40; then
    echo "  pg_restore finished"
  else
    echo "  pg_restore exited non-zero. Warnings alone do that; the counts below decide whether it worked."
  fi

  say "row counts in the target AFTER"
  run_counts dst
  remove_dump; remove_pw; trap - EXIT
  restore_app

  say "done"
  cat <<NEXT
Compare the two count blocks line by line. Equal counts are the proof; a restore that
"finished" with fewer rows is a partial migration, and TeslaMate will not complain - it will
simply have less history than you had.

If they match, the remaining steps are in docs/teslamate-runbook.md:
  1. mint the token pair and sign in   (section 5a)
  2. point the car at the pipeline     scripts/tesla-push-telemetry-config.sh
NEXT
}

case "$MODE" in
  dump)    do_dump ;;
  restore) do_restore ;;
  all)     do_dump; do_restore ;;
esac
