#!/usr/bin/env bash
# Re-render an authentik blueprint Secret from its template, REUSING the client pair already in the
# cluster. RUN IT, DON'T READ IT INTO A SHELL — the operator's login shell is fish; the bash-isms here
# are deliberate and the shebang is the interpreter.
#
# WHY THIS EXISTS
# `authentik/blueprints-*.yaml` is the editable source, but it is only *rendered* into the mounted
# Secret by scripts/setup-<app>-*.sh — and those scripts mint a NEW client pair (and, for Grafana, a
# new admin password) on every run, and refuse to touch an existing Secret without FORCE=1. So before
# this script, the only way to land a one-line blueprint text change — a policy binding, a scope, a
# comment — was to rotate two credentials that had nothing to do with the change.
#
# WHAT IT DOES NOT DO
# It mints nothing, and it does not touch the app's own copy of the client. It READS that copy, which
# is what lets it refuse: if the app's Secret and the mounted blueprint already disagree, re-rendering
# would silently pick one side and make the disagreement permanent. That check is the whole reason to
# read the app Secret instead of scraping the values back out of the old blueprint.
#
# USAGE
#   scripts/rerender-authentik-blueprint.sh <app>            # show the diff, write nothing
#   scripts/rerender-authentik-blueprint.sh <app> --write    # re-encrypt in place
#   apps: observability | tesla-boards | open-webui | mealie
#
# coder, google, opencloud and sure are deliberately absent: their setup scripts hold their
# credentials in different shapes and none has needed a text-only edit yet. An unlisted app is a hard
# stop, not a silent skip.
set -euo pipefail
umask 077

REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$REPO"

usage() {
  echo "usage: $(basename "$0") <app> [--write]" >&2
  echo "  apps: observability | tesla-boards | open-webui | mealie" >&2
  exit 2
}

APP=${1:-}
WRITE=${2:-}
[ -n "$APP" ] || usage
case "$WRITE" in
  --write) WRITE=1 ;;
  "") WRITE=0 ;;
  *) usage ;;
esac

case "$APP" in
  observability)
    TEMPLATE=authentik/blueprints-observability.yaml
    BP_SECRET=apply/10-secrets/authentik-observability-blueprint.yaml
    CRED_SECRET=apply/10-secrets/observability-grafana-oidc.yaml
    PH_ID='${GRAFANA_OIDC_CLIENT_ID}'; PH_SEC='${GRAFANA_OIDC_CLIENT_SECRET}' ;;
  tesla-boards)
    TEMPLATE=authentik/blueprints-grafana.yaml
    BP_SECRET=apply/10-secrets/authentik-grafana-blueprint.yaml
    CRED_SECRET=apply/10-secrets/tesla-grafana-oidc.yaml
    PH_ID='${GRAFANA_OIDC_CLIENT_ID}'; PH_SEC='${GRAFANA_OIDC_CLIENT_SECRET}' ;;
  open-webui)
    TEMPLATE=authentik/blueprints-open-webui.yaml
    BP_SECRET=apply/10-secrets/authentik-open-webui-blueprint.yaml
    CRED_SECRET=apply/10-secrets/open-webui-secrets.yaml
    PH_ID='${OPEN_WEBUI_OIDC_CLIENT_ID}'; PH_SEC='${OPEN_WEBUI_OIDC_CLIENT_SECRET}' ;;
  mealie)
    TEMPLATE=authentik/blueprints-mealie.yaml
    BP_SECRET=apply/10-secrets/authentik-mealie-blueprint.yaml
    CRED_SECRET=apply/10-secrets/mealie-secrets.yaml
    PH_ID='${MEALIE_OIDC_CLIENT_ID}'; PH_SEC='${MEALIE_OIDC_CLIENT_SECRET}' ;;
  *) echo "FAIL: unknown app '$APP' — see usage" >&2; usage ;;
esac

KEY=${SOPS_AGE_KEY_FILE:-$HOME/.config/sops/age/keys.txt}
[ -f "$KEY" ] || { echo "FAIL: no age key at $KEY - set SOPS_AGE_KEY_FILE"; exit 1; }
export SOPS_AGE_KEY_FILE="$KEY"
command -v sops >/dev/null || { echo "FAIL: sops not on PATH"; exit 1; }
[ -f "$TEMPLATE" ] || { echo "FAIL: $TEMPLATE missing"; exit 1; }
[ -f "$BP_SECRET" ] || { echo "FAIL: $BP_SECRET missing — that is a first-time mint; use the setup script"; exit 1; }
[ -f "$CRED_SECRET" ] || { echo "FAIL: $CRED_SECRET missing"; exit 1; }

# Staging lives under apply/10-secrets/ because sops matches creation rules against the path it is
# handed, not the path the output ends up at. The .staging.* name is git-ignored by that directory's
# own rule; plaintext anywhere else is one `git add -A` from a leak.
STAGE_BP=apply/10-secrets/.staging.$(basename "$BP_SECRET")
NEW=$(mktemp); OLD=$(mktemp); ENC=$(mktemp)
cleanup() { rm -f "$STAGE_BP" "$NEW" "$OLD" "$ENC"; }
trap cleanup EXIT INT TERM

# --- the app's own copy of the client, never printed ---------------------------------------------
# Key names differ per app — Grafana uses its config keys, open-webui and Mealie theirs — so the pair
# is found by suffix rather than hard-coded a second time next to the values themselves.
PAIR=$(CRED="$CRED_SECRET" python3 -c '
import os, subprocess, sys, yaml
d = yaml.safe_load(subprocess.run(["sops", "-d", os.environ["CRED"]],
                                  capture_output=True, text=True, check=True).stdout)["stringData"]
cid = next((k for k in d if k.endswith("CLIENT_ID")), None)
csec = next((k for k in d if k.endswith("CLIENT_SECRET")), None)
if not cid or not csec:
    sys.exit("FAIL: no *CLIENT_ID / *CLIENT_SECRET pair in the app Secret")
sys.stdout.write(d[cid] + "\n" + d[csec])')
CID=${PAIR%%$'\n'*}
CSEC=${PAIR#*$'\n'}
if [ -z "$CID" ] || [ -z "$CSEC" ] || [ "$CID" = "$PAIR" ]; then
  echo "FAIL: could not read a client pair from $CRED_SECRET"; exit 1
fi

# --- the rendering currently in git, for the agreement check and the diff -------------------------
BP_KEY=$(sops -d "$BP_SECRET" | OLD="$OLD" python3 -c '
import os, sys, yaml
d = yaml.safe_load(sys.stdin)
keys = list(d["stringData"].keys())
if len(keys) != 1:
    sys.exit(f"FAIL: expected exactly one stringData key, found {len(keys)}")
open(os.environ["OLD"], "w").write(d["stringData"][keys[0]])
print(keys[0])')

# Refuse before writing anything if the two sides already disagree. Re-rendering would take the
# template's copy and hide which half was wrong — the exact failure mode `make <app>-oidc-check`
# exists to surface, and a tool that silently overwrites it is worse than no tool.
if ! grep -qF -- "$CID" "$OLD"; then
  echo "FAIL: the client id in $CRED_SECRET is not the one mounted in $BP_SECRET."
  echo "      The two sides are already out of step; re-rendering would pick one and bury the drift."
  echo "      Establish which is authoritative first (make ${APP}-oidc-check, or the app's setup script)."
  exit 1
fi

# --- render ---------------------------------------------------------------------------------------
TEMPLATE="$TEMPLATE" NEW="$NEW" CID="$CID" CSEC="$CSEC" PH_ID="$PH_ID" PH_SEC="$PH_SEC" python3 - <<'PY'
import os, re, sys
env = os.environ
tpl = open(env["TEMPLATE"]).read()
for ph in (env["PH_ID"], env["PH_SEC"]):
    if ph not in tpl:
        sys.exit(f"FAIL: {ph} not in {env['TEMPLATE']} - template and script disagree")
# Exact string substitution and nothing else: what a reviewer reads in the template is byte-for-byte
# what authentik applies, apart from these two values.
rendered = tpl.replace(env["PH_ID"], env["CID"]).replace(env["PH_SEC"], env["CSEC"])
# The templates' own header prose quotes "${...}" while explaining the mechanism, so match the
# placeholder shape rather than a substring.
leftover = re.findall(r"\$\{[A-Z_]+\}", rendered)
if leftover:
    sys.exit(f"FAIL: unsubstituted placeholder(s): {sorted(set(leftover))}")
open(env["NEW"], "w").write(rendered)
PY

if cmp -s "$NEW" "$OLD"; then
  echo "no change: $BP_SECRET already matches $TEMPLATE"
  exit 0
fi

echo "changes for $BP_SECRET:"
diff -u "$OLD" "$NEW" | sed '1,2d' || true
echo "sha256 of rendered blueprint (first 16): $(python3 -c 'import hashlib,sys; print(hashlib.sha256(open(sys.argv[1],"rb").read()).hexdigest()[:16])' "$NEW")"

if [ "$WRITE" != "1" ]; then
  echo "DRY RUN — nothing written. Re-run with --write to re-encrypt in place."
  exit 0
fi

# --- encrypt and swap -----------------------------------------------------------------------------
BP_SECRET="$BP_SECRET" NEW="$NEW" STAGE_BP="$STAGE_BP" BP_KEY="$BP_KEY" python3 -c '
import os, subprocess, yaml
meta = yaml.safe_load(subprocess.run(["sops", "-d", os.environ["BP_SECRET"]],
                                     capture_output=True, text=True, check=True).stdout)
out = {"apiVersion": "v1", "kind": "Secret",
       "metadata": {"name": meta["metadata"]["name"], "namespace": meta["metadata"]["namespace"]},
       "type": "Opaque",
       # The worker only picks up keys ending in .yaml, so the key name is part of the contract.
       "stringData": {os.environ["BP_KEY"]: open(os.environ["NEW"]).read()}}
yaml.safe_dump(out, open(os.environ["STAGE_BP"], "w"), sort_keys=False, width=100)'

# sops truncates its output file before it starts and dies with "no matching creation rules found"
# AFTER the redirect has already eaten the file — so encrypt to a temp, prove it is real, then swap.
sops --encrypt "$STAGE_BP" > "$ENC"
[ -s "$ENC" ] || { echo "FAIL: sops produced an empty file — $BP_SECRET untouched"; exit 1; }
grep -q "ENC\[" "$ENC" || { echo "FAIL: output is not sops-encrypted — $BP_SECRET untouched"; exit 1; }
cat "$ENC" > "$BP_SECRET"

echo "WROTE $BP_SECRET"
echo "After Flux sync, the worker re-applies because the content hash changed. Proof is the worker"
echo "log for the dispatch and BlueprintInstance.status for the verdict — the log alone is not the"
echo "verdict (docs/authentik-runbook.md)."
