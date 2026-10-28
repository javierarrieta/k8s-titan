#!/usr/bin/env bash
# Copy the members of one authentik group into another, idempotently, and print who moved.
#
# RUN IT, DON'T READ IT INTO A SHELL — the operator's login shell is fish. The bash-isms here are
# deliberate and the shebang is the interpreter.
#
#     scripts/seed-authentik-group.sh <target-group> <source-group> [--dry-run]
#
# WHY THIS EXISTS AND WHY IT TAKES NO NAMES
# apply/50-apps/auth/identity-blueprint.yaml declares four per-app admin groups and deliberately
# does NOT declare humans: naming people in git would make git own their password lifecycle, and
# the file's own adoption order is "seed each group with the humans currently in `authentik Admins`,
# THEN switch that app's group name". This script is that seeding step, made repeatable instead of
# clickwork. It reads the membership out of the live instance at run time, so **no human name ever
# enters this repository** — git owns the intent, authentik owns the list.
#
# WHY IT IS NOT A BLUEPRINT ENTRY
# `authentik_core.group` accepts `users:` in attrs, so membership CAN be declared. It must not be:
# `state: present` re-asserts listed attrs on every discovery pass — that is why every entry in that
# file pins `is_superuser: false` — so a declared `users:` list silently removes anyone added in the
# UI at the next pass, on a schedule nobody watches, with no failure anywhere. Same mechanism as the
# superuser pin, opposite consequence.
#
# WHAT IT REFUSES TO DO
#  * It will not create the target group. A typo'd target name is exactly the failure this exists to
#    prevent downstream: a consumer switched to a group that does not exist drops everyone to the
#    app's fallback role and the login page still looks healthy. Missing target is a hard stop.
#  * It will not remove anyone. It is additive (`group.users.add`), so a re-run is a no-op and a
#    partial seed is recoverable. Removal is a deliberate act, done in the UI or in `ak shell`.
#  * It will not touch `is_superuser`. It prints the target's flag so you can see what you are
#    feeding, and stops there.
#
# NEEDS AN ADMIN CONTEXT. The read-only k8s-reader identity is Forbidden on pods/exec (measured,
# not inferred — docs/authentik-runbook.md §5), so this fails with a Forbidden error from that
# identity rather than doing something partial. Set KUBE_CONTEXT to pick one explicitly.
#
# Nothing here prints a credential. What it prints is usernames and counts, which is what you need
# to decide the next step, and usernames are already in the directory.
set -euo pipefail

usage() {
  sed -n '3,6p' "$0" | sed 's/^# \{0,1\}//'
  echo "usage: $(basename "$0") <target-group> <source-group> [--dry-run]" >&2
  exit 2
}

DRY=0
if [ "${1:-}" = "--help" ] || [ "${1:-}" = "-h" ]; then usage; fi
if [ "${3:-}" = "--dry-run" ]; then DRY=1; fi
[ $# -ge 2 ] || usage
TARGET=$1
SOURCE=$2

NS=${AUTHENTIK_NAMESPACE:-auth}
KCTL=(kubectl)
if [ -n "${KUBE_CONTEXT:-}" ]; then KCTL+=(--context "$KUBE_CONTEXT"); fi

# The python is one argv element passed to `ak shell -c`. Django's shell command runs it and exits,
# which is what makes this scriptable; `ak shell` with no -c is an interactive pty and would hang.
# The names reach the python as environment variables set by the pod's own `sh` (see the exec call
# below), so a group name containing a quote cannot rewrite the code it is about to run.
# `read -d ''` returns 1 when it hits end of input, which a heredoc always does. Under `set -e` that
# kills the script here with no message at all, so swallow the status.
read -r -d '' PY <<'PYCODE' || true
import json, os
from authentik.core.models import Group

src_name = os.environ["SEED_SRC"]
tgt_name = os.environ["SEED_TGT"]
dry = os.environ.get("SEED_DRY") == "1"

def shape(g):
    # sorted() over dicts raises TypeError - dicts are not orderable - so sort by the username.
    members = [{"username": u.username, "type": u.type} for u in g.users.all()]
    return {"name": g.name, "is_superuser": g.is_superuser,
            "members": sorted(members, key=lambda m: m["username"]),
            "count": g.users.count()}

src = Group.objects.filter(name=src_name).first()
if src is None:
    print(json.dumps({"ok": False, "reason": "source-group-missing", "group": src_name}))
    raise SystemExit(0)

tgt = Group.objects.filter(name=tgt_name).first()
if tgt is None:
    print(json.dumps({"ok": False, "reason": "target-group-missing", "group": tgt_name,
                      "hint": "the blueprint has not applied, or this name is a typo"}))
    raise SystemExit(0)

before = {u.username for u in tgt.users.all()}
before_shape = shape(tgt)   # capture BEFORE the add, or target_before reports the after-state
to_add = [u for u in src.users.all() if u.username not in before]
if to_add and not dry:
    tgt.users.add(*to_add)
    # Drop the stale related-manager cache before re-reading, or target_after reports the old count.
    tgt = Group.objects.get(pk=tgt.pk)

print(json.dumps({
    "ok": True, "dry": dry,
    "source": shape(src), "target_before": before_shape,
    "added": sorted(u.username for u in to_add),
    "target_after": shape(tgt),
}))
PYCODE

# The names and the code all travel as argv elements, never interpolated into a shell string.
# `kubectl exec` has NO -e flag - that is `docker exec` / `kubectl run`, and the mistake was made
# here and fails with `unknown shorthand flag: 'e'` before anything reaches the pod. So the pod's own
# `sh` sets the variables, and `sh` is the one binary guaranteed in any image; `env` is not.
# The `_` after the -c script is Django's: sh -c SCRIPT consumes the next word as $0.
if ! OUT=$("${KCTL[@]}" exec -n "$NS" deploy/authentik-worker -- \
             sh -c 'SEED_SRC="$1"; SEED_TGT="$2"; SEED_DRY="$3"; export SEED_SRC SEED_TGT SEED_DRY; ak shell -c "$4"' \
             _ "$SOURCE" "$TARGET" "$DRY" "$PY" 2>&1); then
  echo "seed-authentik-group: the shell call failed. Last lines:" >&2
  printf '%s\n' "$OUT" | tail -5 >&2
  case "$OUT" in
    *Forbidden*) echo "  ... it said Forbidden: this needs an admin context, not k8s-reader. Set KUBE_CONTEXT." >&2 ;;
  esac
  exit 1
fi

# The shell prints a banner before the JSON, so take the last JSON line rather than assuming stdout
# is clean. `|| true` is load-bearing: under `set -o pipefail` a no-match grep returns 1 through the
# pipeline, and without it `set -e` kills the script here silently instead of reaching the explicit
# "no verdict line" branch below.
JSON=$(printf '%s\n' "$OUT" | { grep -E '^\{"ok":' || true; } | tail -1)
if [ -z "$JSON" ]; then
  echo "seed-authentik-group: no verdict line in the shell output; refusing to guess." >&2
  printf '%s\n' "$OUT" | tail -10 >&2
  exit 1
fi

if ! command -v jq >/dev/null 2>&1; then
  echo "$JSON"
  echo "seed-authentik-group: jq is missing, so the raw verdict is above unformatted." >&2
  exit 0
fi

printf '%s\n' "$JSON" | jq -r '
  if .ok | not then
    "STOP: \(.reason) — `.\(.group)` is not a group in this instance. \(.hint // "")"
  else
    "source  \(.source.name)  superuser=\(.source.is_superuser)  members=\(.source.count)",
    "target  \(.target_before.name)  superuser=\(.target_before.is_superuser)  members=\(.target_before.count)",
    (if (.added | length) == 0 then "added   none (already seeded)"
     else "added   \(.added | join(", "))" end),
    "now     \(.target_after.count) member(s): \(.target_after.members | map(.username + ":" + .type) | join(", "))",
    (if .dry then "DRY RUN — nothing changed." else "COMMITTED — membership is live now." end)
  end'

printf '%s\n' "$JSON" | jq -e '.ok' >/dev/null
