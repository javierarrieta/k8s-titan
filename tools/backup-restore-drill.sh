#!/usr/bin/env bash
# PV restore drill for titan's restic backups (issue #101).
#
# Proves that a volume backed up by apply/70-backup/ can be put back from the restic
# repository and is the bytes that were taken -- without touching the live PVC.
#
# WHY THIS EXISTS. apply/70-backup/ has never been restored (spec 2026-10-22 section 10).
# A backup that has only ever been observed succeeding is a hypothesis: the repository
# could be unreadable, the password wrong, the tags not what a restore expects, and every
# nightly job would still report success. This is the falsifiable version of "the backups
# work".
#
# WHAT IT DELIBERATELY DOES NOT DO:
#   * It never mounts the source PVC. The restore Job mounts only the scratch PVC, so a
#     green result cannot come from reading the live volume.
#   * It never writes to a PVC whose name does not end in -drill.
#   * It never puts a credential on the operator's machine. restic runs in a Job that
#     envFrom's backup-minio-secrets; this script only applies Jobs and reads their logs.
#
# Needs an admin context. The read-only k8s-reader identity cannot create Jobs (measured
# 2026-11-03: `auth can-i create job -n apps` -> no), which is why this is operator-run.
#
#   tools/backup-restore-drill.sh probe   [--context CTX] [--namespace NS] [--pvc PVC]
#   tools/backup-restore-drill.sh restore [--context CTX] [--namespace NS] [--pvc PVC] [--keep]
#   tools/backup-restore-drill.sh cleanup [--context CTX] [--namespace NS] [--pvc PVC]
#
# Default target is mealie/mealie-data: the smallest opted-in volume (5Gi) with real
# user content, so the first drill is the cheapest honest one.
#
# Exit 0 = the stage's checks passed. Exit 1 = a guard refused, the job failed, or the
# restored bytes did not match the repository (reported as DRILL_RESULT ... match=no).

set -euo pipefail

# Same digest the nightly jobs pin (apply/70-backup/runner.yaml, RESTIC_IMAGE). Keeping it
# here rather than reading it off a live pod means a bump in one place and not the other is
# visible in review; it also means the drill cannot quietly pass on a newer restic than the
# one production uses.
RESTIC_IMAGE="restic/restic@sha256:136600b6ff6843d61d355f7f71f460a166429f35de6fd11b568fece3c9a4d510"

CTX="${DRILL_CONTEXT:-}"
NS="mealie"
PVC="mealie-data"
KEEP=0
STAGE="${1:-}"
shift 2>/dev/null || true

while [ $# -gt 0 ]; do
  case "$1" in
    --context)   CTX="$2"; shift 2 ;;
    --namespace) NS="$2"; shift 2 ;;
    --pvc)       PVC="$2"; shift 2 ;;
    --keep)      KEEP=1; shift ;;
    -h|--help)   sed -n '2,32p' "$0" | sed 's/^# \{0,1\}//'; exit 2 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

case "$STAGE" in probe|restore|cleanup) ;; *) sed -n '2,32p' "$0" | sed 's/^# \{0,1\}//'; exit 2 ;; esac
[ -n "$CTX" ] || { echo "REFUSE: no context. Pass --context <admin ctx> or set DRILL_CONTEXT." >&2; exit 1; }

SCRATCH="${PVC}-drill"
K=(kubectl --context "$CTX" -n "$NS")
TS="$(date +%m%d%H%M)"
PROBE_JOB="drill-probe-${TS}"
RESTORE_JOB="drill-restore-${TS}"

# ---- guards. Every one is a refusal, not a warning: this writes to a live cluster. ----
if ! "${K[@]}" auth can-i create job >/dev/null 2>&1; then
  echo "REFUSE: cannot create jobs in $NS with context '$CTX'. Needs an admin context; k8s-reader is read-only." >&2
  exit 1
fi

PHASE=$("${K[@]}" get pvc "$PVC" -o jsonpath='{.status.phase}' 2>/dev/null || true)
[ "$PHASE" = "Bound" ] || { echo "REFUSE: pvc/$PVC in $NS is '${PHASE:-absent}', not Bound." >&2; exit 1; }

CLASS_ANN=$("${K[@]}" get pvc "$PVC" -o jsonpath='{.metadata.annotations.backup\.titan\.arrieta\.eu/class}' 2>/dev/null || true)
case "$CLASS_ANN" in
  ""|none) echo "REFUSE: pvc/$PVC carries no backup.titan.arrieta.eu/class, so nothing was ever backed up. Refusing to report a restore for a volume with no backup." >&2; exit 1 ;;
esac

case "$SCRATCH" in *-drill) ;; *) echo "REFUSE: scratch name '$SCRATCH' does not end in -drill." >&2; exit 1 ;; esac

SIZE=$("${K[@]}" get pvc "$PVC" -o jsonpath='{.spec.resources.requests.storage}')

# ---- the in-pod scripts. They run under the restic image's /bin/sh, which is busybox
# ---- ash: POSIX only, no bashisms, no jq.
#
# THE PATH PREFIX, which is the trap most likely to produce a fake pass: `restic backup
# /volume` stores paths as `volume/...`, so `restic restore --target /restore` lands at
# /restore/volume/... and NOT at /restore/.... A drill that looks for files directly under
# /restore reports "restored nothing" while restic exits 0.
# WHICH SNAPSHOT IS THE NEWEST, and the flag that must never be used. `--last` is NOT a
# count. At v0.19.1 it is `f.BoolVar(&opts.last, "last", false, ...)` and already marked
# deprecated in favour of `--latest n`, so `--last 1` parses as the boolean plus a POSITIONAL
# snapshot id of "1", which matches nothing -- and restic then says `Ignoring "filters":
# explicit snapshot ids are given`, dropping the tag filter and returning empty. The second
# live probe died exactly this way, on the very flag the backup spec warns about: techdelivery
# once let `restic snapshots --last 1` misparse in 0.19.x and every tag-based restore claimed
# no snapshot existed.
#
# So: no count flag at all. The short id comes off the human-readable table, whose column
# layout is steadier than any JSON key and needs no version-conditional flag; restic sorts
# snapshots ascending, so the last data row is the newest. The JSON path is the fallback.
#
# THE JSON KEYS, checked against restic's own source (cmd/restic/cmd_snapshots.go,
# cmd_ls.go at v0.19.1) rather than guessed -- the first guess printed an empty snapshot id.
#   * `snapshots --json` emits one compact line via json.Encoder, and the id fields are
#     "id" (full 64 hex) and "short_id". There is no "snapshot" key; that name belongs to
#     older releases' ls output. "id" cannot collide with "short_id" because the literal
#     requires a quote immediately before `id`.
#   * `ls --json` emits one compact object per line, with "type":"file" and "path" and
#     "size". The older field name was "structure-type"; both are accepted below so the
#     drill does not break on a restic version bump in either direction.
RESTIC_PROBE='
set -eu
export TMPDIR=/tmp
sh /preflight/preflight.sh || { echo "ABORT: preflight failed -- S3 endpoint unreachable" >&2; exit 1; }
restic version
echo "== snapshots for tag $BACKUP_TAG =="
restic snapshots --tag "$BACKUP_TAG" | tail -8
SNAP=$(restic snapshots --tag "$BACKUP_TAG" | sed -n "s/^\([0-9a-f]\{8\}\)  .*/\1/p" | tail -1)
[ -n "$SNAP" ] || SNAP=$(restic snapshots --tag "$BACKUP_TAG" --json | tr "," "\n" | sed -n "s/.*\"short_id\":\"\([0-9a-f]*\)\".*/\1/p" | tail -1)
echo "LATEST_SNAPSHOT ${SNAP:-<none>}"
if [ -n "$SNAP" ]; then
  # Dumping the first ls records is deliberate: if restic ever changes the JSON shape
  # again, the raw lines are in the log instead of a silent empty file list.
  echo "== first ls --json records (format evidence) =="
  restic ls --json "$SNAP" | head -3
fi
'

# THE PATH PREFIX, which the live evidence disproved. The assumption was that `restic backup
# /volume` strips the leading slash and stores `volume/...`. It does not: restic 0.19.1's
# `ls --json` reports `"path":"/volume/.secret"` and `"paths":["/volume"]`, slash intact.
# Comparing those strings against `find /restore` output, which has no leading slash, would
# report paths_match=no on a perfectly good restore. So both sides are normalised by
# stripping a leading `/`, and `restic dump` is offered the stored form first and the
# stripped form second, because which one restic wants is exactly the kind of thing that
# changed once already.
RESTIC_RESTORE='
set -eu
export TMPDIR=/tmp
sh /preflight/preflight.sh || { echo "ABORT: preflight failed -- S3 endpoint unreachable" >&2; exit 1; }

SNAP=$(restic snapshots --tag "$BACKUP_TAG" | sed -n "s/^\([0-9a-f]\{8\}\)  .*/\1/p" | tail -1)
[ -n "$SNAP" ] || SNAP=$(restic snapshots --tag "$BACKUP_TAG" --json | tr "," "\n" | sed -n "s/.*\"short_id\":\"\([0-9a-f]*\)\".*/\1/p" | tail -1)
[ -n "$SNAP" ] || { echo "ABORT: no snapshot found for tag $BACKUP_TAG" >&2; exit 1; }
echo "restoring snapshot $SNAP of tag $BACKUP_TAG into /restore"

# --target only, no --overwrite: the scratch volume is empty by construction, and an
# overwrite flag in a script invites a later edit that restores onto real data.
restic restore "$SNAP" --target /restore
echo "== restored tree =="; ls -la /restore
[ -d /restore/volume ] || echo "WARNING: /restore/volume is absent -- restic did not store paths under volume/. Check the prefix assumption before believing any count below." >&2

# Three independent checks, each comparing the repository against the restored volume.
# None of them can read the live PVC, because it is not mounted in this pod.
# Only regular files on both sides: symlinks, devices and fifos are excluded from the
# expected list by the type filter and from the tree by `find -type f`, so the two counts
# are the same population rather than two different ones that happen to agree.
# Sorted in stored form first; every stored path here begins with `/`, so stripping that
# prefix afterwards preserves the order and the two files stay line-aligned.
restic ls --json "$SNAP" | grep -E "\"(type|structure-type)\":\"file\"" \
  | sed -n "s/.*\"path\":\"\([^\"]*\)\".*/\1/p" | sort > /tmp/expected_raw.txt
sed "s|^/||" /tmp/expected_raw.txt > /tmp/expected.txt
EXPECTED_FILES=$(wc -l < /tmp/expected.txt | tr -d " ")
EXPECTED_BYTES=$(restic ls --json "$SNAP" | grep -E "\"(type|structure-type)\":\"file\"" \
  | sed -n "s/.*\"size\":\([0-9]*\).*/\1/p" | awk "{s+=\$1} END {print s+0}")

find /restore -type f | sed "s|^/restore/||" | sort > /tmp/actual.txt
ACTUAL_FILES=$(wc -l < /tmp/actual.txt | tr -d " ")
ACTUAL_BYTES=0
if [ "$ACTUAL_FILES" -gt 0 ]; then
  ACTUAL_BYTES=$(find /restore -type f -exec wc -c {} + | tail -1 | awk "{print \$1}")
fi

PATHS_MATCH=no
if [ "$EXPECTED_FILES" = "$ACTUAL_FILES" ] && cmp -s /tmp/expected.txt /tmp/actual.txt; then
  PATHS_MATCH=yes
fi

# Byte-level proof on a sample: the same file read out of the repository and off the
# restored volume. `restic dump <snapshotID> <file>` is the content command -- `restic
# cat` is for repository internals (config, pack ID, blob ID) and rejects a file path.
# The path wants the volume/ prefix, as stored.
#
# `while read` from a file, not `for p in $(...)`: word splitting on a filename containing
# a space would sample the wrong paths and report a mismatch that is not real. Same reason
# runner.sh redirects from a file instead of piping into the loop -- a pipeline would also
# run the loop in a subshell and the counters would die with it.
head -5 /tmp/expected_raw.txt > /tmp/sample.txt
SAMPLES=0; SAMPLES_OK=0
while IFS= read -r raw; do
  [ -n "$raw" ] || continue
  norm=$(printf '%s' "$raw" | sed "s|^/||")
  # Stored form first, stripped form second; a failed dump must not be scored as a hash of
  # empty input, which is why the exit status of the dump call itself decides.
  if ! restic dump "$SNAP" "$raw" > /tmp/sample.bin 2>/dev/null; then
    restic dump "$SNAP" "/$norm" > /tmp/sample.bin 2>/dev/null || { echo "CANNOT_DUMP $raw" >&2; continue; }
  fi
  A=$(sha256sum < /tmp/sample.bin | cut -c1-64)
  B=$(sha256sum "/restore/$norm" | cut -c1-64)
  SAMPLES=$((SAMPLES + 1))
  if [ "$A" = "$B" ]; then SAMPLES_OK=$((SAMPLES_OK + 1)); else echo "MISMATCH $raw repo=$A disk=$B" >&2; fi
done < /tmp/sample.txt

MATCH=no
if [ "$PATHS_MATCH" = yes ] && [ "$EXPECTED_BYTES" = "$ACTUAL_BYTES" ] \
   && [ "$SAMPLES" -gt 0 ] && [ "$SAMPLES" -eq "$SAMPLES_OK" ]; then MATCH=yes; fi

echo "DRILL_RESULT target=$BACKUP_TAG snapshot=$SNAP files_expected=$EXPECTED_FILES files_restored=$ACTUAL_FILES bytes_expected=$EXPECTED_BYTES bytes_restored=$ACTUAL_BYTES paths_match=$PATHS_MATCH content_samples=$SAMPLES_OK/$SAMPLES match=$MATCH"
[ "$MATCH" = yes ]
'

job_manifest() {
  # $1 = job name, $2 = probe|restore
  local name="$1" kind="$2" script extra_mounts="" extra_volumes="" caps='"DAC_OVERRIDE"'
  if [ "$kind" = probe ]; then script="$RESTIC_PROBE"; else script="$RESTIC_RESTORE"; fi
  if [ "$kind" = restore ]; then
    # CAP_CHOWN, and this is the finding a live run produced that no amount of reading the
    # backup manifests would have: the nightly jobs run `drop ALL` + DAC_OVERRIDE, which is
    # exactly right for READING a heterogeneous-uid volume and exactly wrong for WRITING one
    # back. Restoring mealie's files to uid 911 needs lchown, and root without CAP_CHOWN gets
    # EPERM -- restic wrote all 12.285 MiB and then exited fatal on 21 errors. A real
    # disaster would discover this at the worst possible moment, which is the point of
    # drilling.
    #
    # CHOWN alone was not enough. The next live run failed on `failed to restore timestamp of
    # "…": operation not permitted` -- utimensat to an arbitrary time requires ownership of the
    # file or CAP_FOWNER, and restic had just chowned those files to uid 911, so root without
    # FOWNER was refused on its own output. Two errors, two round trips, and the lesson is the
    # general one rather than the specific one: A RESTORE NEEDS MORE PRIVILEGE THAN A BACKUP,
    # and the set is discovered from the kernel's refusals, not from the backup manifests.
    #
    # So the restore container gets the standard restore-as-root set, each member justified
    # rather than cargo-culted:
    #   CHOWN   lchown to the stored uid/gid
    #   FOWNER  utimensat and chmod on files whose owner is not us -- i.e. everything
    #   FSETID  clear setgid/setuid bits that chmod would otherwise drop
    #   SETUID  restic switches fsuid while writing so files land owned correctly
    #   SETGID  the same for fsgid
    #   DAC_OVERRIDE  read past mode bits, as on the backup side
    # All six are in the Pod Security `baseline` allowed-capability list, which is why the
    # backup jobs' DAC_OVERRIDE was accepted in these namespaces at all.
    caps='"DAC_OVERRIDE", "CHOWN", "FOWNER", "FSETID", "SETUID", "SETGID"'
    # The scratch volume, and ONLY the scratch volume. The source PVC is deliberately not
    # mounted: a restore that could read the live data would prove nothing.
    extra_mounts='        - name: target
          mountPath: /restore'
    extra_volumes='      - name: target
        persistentVolumeClaim:
          claimName: PLACEHOLDER'
  fi
  cat <<EOF
apiVersion: batch/v1
kind: Job
metadata:
  name: $name
  namespace: $NS
  labels:
    app: backup
    app.kubernetes.io/part-of: pv-backup
    app.kubernetes.io/component: pv-backup-drill
    backup/target: $PVC
spec:
  backoffLimit: 0
  activeDeadlineSeconds: 3600
  ttlSecondsAfterFinished: 86400
  template:
    metadata:
      labels:
        app: backup
        app.kubernetes.io/part-of: pv-backup
        app.kubernetes.io/component: pv-backup-drill
        backup/target: $PVC
    spec:
      restartPolicy: Never
      # Reuse the nightly backup ServiceAccount: it already holds exactly what a restic
      # client needs in this namespace, so rbac.yaml stays the only place that governs it.
      serviceAccountName: backup-job
      # root + DAC_OVERRIDE, matching the backup jobs. The scratch volume is freshly
      # provisioned and root-owned; no fsGroup, for the reason given in runner.yaml.
      securityContext:
        runAsNonRoot: false
        runAsUser: 0
        seccompProfile: {type: RuntimeDefault}
      containers:
      - name: restic
        image: $RESTIC_IMAGE
        command: ["/bin/sh", "-c"]
        args:
        - |
$(printf '%s\n' "$script" | sed 's/^/          /')
        env:
        - name: BACKUP_TAG
          value: $PVC
        envFrom:
        - secretRef:
            name: backup-minio-secrets
        securityContext:
          allowPrivilegeEscalation: false
          seccompProfile: {type: RuntimeDefault}
          capabilities:
            drop: ["ALL"]
            add: [$caps]
        resources:
          requests: {cpu: 100m, memory: 512Mi}
          limits: {cpu: 500m, memory: 1Gi}
        volumeMounts:
        - name: tmp
          mountPath: /tmp
        - name: preflight
          mountPath: /preflight
          readOnly: true
$extra_mounts
      volumes:
      - name: tmp
        emptyDir: {sizeLimit: 2Gi}
      - name: preflight
        configMap:
          name: backup-preflight
          defaultMode: 0555
$extra_volumes
EOF
}

wait_for_job() {
  local name="$1" timeout="${2:-1800}" waited=0 ok fail
  while [ "$waited" -lt "$timeout" ]; do
    ok=$("${K[@]}" get job "$name" -o jsonpath='{.status.succeeded}' 2>/dev/null || true)
    fail=$("${K[@]}" get job "$name" -o jsonpath='{.status.failed}' 2>/dev/null || true)
    [ "${ok:-0}" != "0" ] && [ -n "${ok:-}" ] && { echo "job/$name succeeded"; return 0; }
    [ "${fail:-0}" != "0" ] && [ -n "${fail:-}" ] && { echo "job/$name FAILED" >&2; return 1; }
    sleep 10; waited=$((waited + 10))
  done
  echo "job/$name did not finish within ${timeout}s (activeDeadlineSeconds will kill it)" >&2
  return 1
}

show_logs() { "${K[@]}" logs "job/$1" 2>&1 || true; }

case "$STAGE" in
  probe)
    echo "probe: ns=$NS pvc=$PVC class=$CLASS_ANN size=$SIZE ctx=$CTX"
    job_manifest "$PROBE_JOB" probe | "${K[@]}" apply -f -
    if wait_for_job "$PROBE_JOB" 600; then show_logs "$PROBE_JOB"; else show_logs "$PROBE_JOB"; exit 1; fi
    "${K[@]}" delete job "$PROBE_JOB" --ignore-not-found >/dev/null
    ;;

  restore)
    echo "restore: ns=$NS pvc=$PVC -> scratch pvc/$SCRATCH (class local-path, size $SIZE)"
    # local-path, NOT local-path-retain. Retain leaves a Released PV behind when the
    # scratch PVC is deleted, and titan already carries five of those from earlier
    # provisioning churn (issue #114). A drill that adds litter is a drill people stop
    # running.
    #
    # No backup.titan.arrieta.eu/class annotation here on purpose. That annotation is the
    # opt-in the discovery CronJob selects on, so an annotated scratch volume would be
    # swept into the nightly backup set and a drill artifact would become production data.
    "${K[@]}" apply -f - <<EOF
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: $SCRATCH
  namespace: $NS
  labels:
    app.kubernetes.io/part-of: pv-backup
    app.kubernetes.io/component: pv-backup-drill
  annotations:
    drill.titan.arrieta.eu/purpose: "restore drill for pvc/$PVC -- safe to delete"
    drill.titan.arrieta.eu/source: "$NS/$PVC"
spec:
  accessModes: ["ReadWriteOnce"]
  storageClassName: local-path
  resources:
    requests:
      storage: $SIZE
EOF
    # claimName is substituted after generation so the guarded scratch name is the only
    # value that can ever land there.
    job_manifest "$RESTORE_JOB" restore | sed "s|claimName: PLACEHOLDER|claimName: $SCRATCH|" \
      | "${K[@]}" apply -f -
    RC=0
    if wait_for_job "$RESTORE_JOB" 3600; then show_logs "$RESTORE_JOB"; else show_logs "$RESTORE_JOB"; RC=1; fi
    if [ "$KEEP" -eq 1 ]; then
      echo "KEPT: pvc/$SCRATCH and job/$RESTORE_JOB. Clean up with: $0 cleanup --context $CTX --namespace $NS --pvc $PVC"
    else
      "${K[@]}" delete job "$RESTORE_JOB" --ignore-not-found >/dev/null
      "${K[@]}" delete pvc "$SCRATCH" --ignore-not-found >/dev/null
      echo "cleaned up scratch pvc/$SCRATCH"
    fi
    exit "$RC"
    ;;

  cleanup)
    "${K[@]}" delete job -l "app.kubernetes.io/component=pv-backup-drill,backup/target=$PVC" --ignore-not-found
    "${K[@]}" delete pvc "$SCRATCH" --ignore-not-found
    echo "cleanup done in $NS (scratch pvc/$SCRATCH)"
    ;;
esac
