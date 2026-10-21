#!/usr/bin/env bash
# Mint Grafana's OIDC client and its local admin password, and write each to every place it has to
# appear. RUN IT, DON'T READ IT INTO A SHELL — the operator's login shell is fish, which has no
# heredocs and no `read -rs -p`; the bash-isms here are deliberate and the shebang is the interpreter.
#
# WHY A SCRIPT AND NOT A UI CLICK
# authentik takes this configuration as a blueprint, so generating the client here and handing it to
# both sides means a rebuilt authentik gets Grafana's client back from git rather than from someone's
# memory, and nothing is ever pasted into a chat transcript. Same reasoning as
# scripts/setup-grafana-oidc.sh, which this file is modelled on.
#
# THREE FILES, TWO CREDENTIALS
#   - the OIDC pair: authentik's blueprint AND Grafana's env. If they disagree, every login fails
#     with an OIDC error that reads like a Grafana bug. `make observability-oidc-check` proves it.
#   - the admin credential: Grafana's escape hatch, held once, in one Secret the Deployment envFroms.
#
# Nothing prints a value. What you see is a truncated SHA-256 per file, so a re-run can be compared
# against the last one without a secret being on screen.
set -euo pipefail

# The plaintext staging files exist for seconds, but "seconds" is the whole exposure window and a
# world-readable credential file is a real one. Cheap to close, so close it.
umask 077

REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$REPO"

TEMPLATE=authentik/blueprints-observability.yaml
BP_SECRET=apply/10-secrets/authentik-observability-blueprint.yaml
APP_SECRET=apply/10-secrets/observability-grafana-oidc.yaml
ADMIN_SECRET=apply/10-secrets/observability-grafana-admin.yaml
STAGE_BP=apply/10-secrets/.staging.authentik-observability-blueprint.yaml
STAGE_APP=apply/10-secrets/.staging.observability-grafana-oidc.yaml
STAGE_ADMIN=apply/10-secrets/.staging.observability-grafana-admin.yaml
KEY=${SOPS_AGE_KEY_FILE:-$HOME/.config/sops/age/keys.txt}

# Never leave plaintext behind, whatever fails. All three staging paths are git-ignored by name
# (apply/10-secrets/.staging.*.yaml) and sit under apply/10-secrets/ because sops picks its
# recipients from the file's own path, not from your intent.
# EXIT alone is not enough: bash does not run an EXIT trap for an untrapped SIGINT/SIGTERM, so a
# Ctrl-C between the plaintext write and `sops --encrypt` would leave plaintext on disk. The EXIT trap
# still fires from inside these, so the cleanup is defined once.
cleanup() { rm -f "$STAGE_BP" "$STAGE_APP" "$STAGE_ADMIN"; }
trap cleanup EXIT
trap 'cleanup; exit 130' INT TERM

for tool in sops python3; do
  command -v "$tool" >/dev/null || { echo "FAIL: $tool not on PATH"; exit 1; }
done
[ -f "$KEY" ] || { echo "FAIL: no age key at $KEY - set SOPS_AGE_KEY_FILE"; exit 1; }
export SOPS_AGE_KEY_FILE="$KEY"
[ -f "$TEMPLATE" ] || { echo "FAIL: $TEMPLATE missing - nothing to render"; exit 1; }

existing=()
for f in "$BP_SECRET" "$APP_SECRET" "$ADMIN_SECRET"; do
  [ -f "$f" ] && existing+=("$f")
done
if [ ${#existing[@]} -gt 0 ]; then
  echo "FAIL: these already exist and would be replaced with NEW credentials:"
  printf '  %s\n' "${existing[@]}"
  echo "Grafana would then present a client authentik no longer recognises, and every OIDC login"
  echo "fails until both sides are re-rendered together. If that is what you want, re-run with FORCE=1."
  [ "${FORCE:-0}" = "1" ] || exit 1
fi

CID=$(python3 -c 'import uuid; print(uuid.uuid4())')
CSEC=$(python3 -c 'import secrets; print(secrets.token_hex(32))')
APASS=$(python3 -c 'import secrets; print(secrets.token_urlsafe(24))')

TEMPLATE="$TEMPLATE" STAGE_BP="$STAGE_BP" STAGE_APP="$STAGE_APP" STAGE_ADMIN="$STAGE_ADMIN" \
CID="$CID" CSEC="$CSEC" APASS="$APASS" python3 - <<'PY'
import os, re, sys, yaml

env = os.environ
tpl = open(env["TEMPLATE"]).read()
for ph in ("${GRAFANA_OIDC_CLIENT_ID}", "${GRAFANA_OIDC_CLIENT_SECRET}"):
    if ph not in tpl:
        sys.exit(f"FAIL: {ph} not found in {env['TEMPLATE']} - template and script disagree")

# Exact string substitution and nothing else: what a reviewer reads in the template is byte-for-byte
# what authentik applies, apart from these two values.
rendered = (tpl.replace("${GRAFANA_OIDC_CLIENT_ID}", env["CID"])
              .replace("${GRAFANA_OIDC_CLIENT_SECRET}", env["CSEC"]))
# The template's own header prose mentions "${...}" while explaining the mechanism, so a crude
# substring check fires on its own documentation. Match the placeholder shape instead.
leftover = re.findall(r"\$\{[A-Z_]+\}", rendered)
if leftover:
    sys.exit(f"FAIL: unsubstituted placeholder(s) remain: {leftover}")

def dump(path, obj):
    with open(path, "w") as fh:
        yaml.safe_dump(obj, fh, sort_keys=False, width=100)

dump(env["STAGE_BP"], {
    "apiVersion": "v1", "kind": "Secret",
    "metadata": {"name": "authentik-observability-blueprint", "namespace": "auth"},
    "type": "Opaque",
    # The worker only picks up keys ending in .yaml, so the key name is part of the contract.
    "stringData": {"observability.yaml": rendered},
})

# Grafana's copy. The names are the config keys Grafana reads, so envFrom injects them with no
# mapping and no chance of a typo'd alias between the Secret and the Deployment.
dump(env["STAGE_APP"], {
    "apiVersion": "v1", "kind": "Secret",
    "metadata": {"name": "observability-grafana-oidc", "namespace": "observability"},
    "type": "Opaque",
    "stringData": {
        "GF_AUTH_GENERIC_OAUTH_CLIENT_ID": env["CID"],
        "GF_AUTH_GENERIC_OAUTH_CLIENT_SECRET": env["CSEC"],
    },
})

# The escape hatch. GF_AUTH_BASIC_ENABLED stays true in the Deployment precisely so this account is
# usable when the OIDC config is the thing that is broken.
dump(env["STAGE_ADMIN"], {
    "apiVersion": "v1", "kind": "Secret",
    "metadata": {"name": "observability-grafana-admin", "namespace": "observability"},
    "type": "Opaque",
    "stringData": {
        "GF_SECURITY_ADMIN_USER": "admin",
        "GF_SECURITY_ADMIN_PASSWORD": env["APASS"],
    },
})
PY

# Encrypt all three BEFORE any of them lands in place. Moving per-file would leave the blueprint Secret
# holding a new client while observability-grafana-oidc still held the old one if sops failed on the
# second file — the exact split this change exists to prevent, reachable from a transient sops error
# rather than from anyone editing one side. `make observability-oidc-check` does catch the split, but
# a gate that reports a self-inflicted wound is worse than one that cannot happen.
for f in "$STAGE_BP" "$STAGE_APP" "$STAGE_ADMIN"; do
  sops --encrypt --in-place "$f"
done
for pair in "$STAGE_BP:$BP_SECRET" "$STAGE_APP:$APP_SECRET" "$STAGE_ADMIN:$ADMIN_SECRET"; do
  f=${pair%:*}; dest=${pair#*:}
  mv "$f" "$dest"
  echo "wrote $dest  (fingerprint $(python3 -c "import hashlib,sys;print(hashlib.sha256(open(sys.argv[1],'rb').read()).hexdigest()[:12])" "$dest"))"
done

cat <<'DONE'

Done. Three files, two credentials, all encrypted.

Still to do, in order:
  1. List all three in apply/10-secrets/kustomization.yaml, and mount the blueprint in
     apply/50-apps/auth/authentik.yaml (blueprints.secrets AND the reloader annotation).
  2. make observability-oidc-check  proves the two copies, the mount and the host agree.
  3. Merge, and let the authentik worker apply the blueprint (hourly, or force it — see
     docs/grafana-runbook.md "Forcing the blueprint"). Then CONFIRM it landed: a mounted blueprint that
     silently never applied is a recorded failure here, not a hypothetical. Step 6 of that runbook's §7
     prints the BlueprintInstance rows; do it before debugging any login.
  4. Sign in with authentik once and confirm the role you expected. GF_AUTH_BASIC_ENABLED stays
     true on purpose: it is the way back in if the OIDC config is ever wrong.
DONE
