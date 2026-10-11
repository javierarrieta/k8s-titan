#!/usr/bin/env bash
# Render authentik/blueprints-google.yaml into a sops-encrypted Secret under apply/10-secrets/.
#
# Same shape as scripts/setup-coder-secrets.sh, for the same reason: the blueprint carries a live
# credential, so it has to arrive as a Secret, and sops picks its recipients from the file's own path
# (.sops.yaml keys on apply/10-secrets/*.yaml), so the plaintext has to be staged there first.
#
# Credentials come from one of:
#   GOOGLE_CLIENT_JSON=/path/to/client_secret.json   (the file Google Cloud downloads)
#   GOOGLE_CLIENT_ID + GOOGLE_CLIENT_SECRET          (exported by hand)
# Nothing is generated here - unlike coder's client, this credential is minted by Google, so there is
# no "generate if unset" branch. Guessing at a Google secret would only produce a source that fails at
# the first login attempt, three time zones away from the mistake.
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEMPLATE="$REPO/authentik/blueprints-google.yaml"
BP_SECRET="$REPO/apply/10-secrets/authentik-google-blueprint.yaml"
STAGE_BP="$REPO/apply/10-secrets/.staging.authentik-google-blueprint.yaml"

cd "$REPO"
[ -f "$TEMPLATE" ] || { echo "FAIL: template missing: $TEMPLATE"; exit 1; }
command -v sops >/dev/null || { echo "FAIL: sops not installed"; exit 1; }

# --- resolve credentials ------------------------------------------------------------------------
if [ -n "${GOOGLE_CLIENT_JSON:-}" ]; then
  [ -f "$GOOGLE_CLIENT_JSON" ] || { echo "FAIL: GOOGLE_CLIENT_JSON not a file: $GOOGLE_CLIENT_JSON"; exit 1; }
  read -r CID CSEC <<<"$(python3 -c '
import json,sys
d=json.load(open(sys.argv[1]))
root=d.get("web") or d.get("installed") or {}
cid,sec=root.get("client_id"),root.get("client_secret")
if not cid or not sec: sys.exit("FAIL: no client_id/client_secret in "+sys.argv[1])
print(cid, sec)
' "$GOOGLE_CLIENT_JSON")"
  echo "credentials: read from ${GOOGLE_CLIENT_JSON}"
else
  CID="${GOOGLE_CLIENT_ID:-}"
  CSEC="${GOOGLE_CLIENT_SECRET:-}"
  [ -n "$CID" ] && [ -n "$CSEC" ] || { echo "FAIL: set GOOGLE_CLIENT_JSON, or GOOGLE_CLIENT_ID + GOOGLE_CLIENT_SECRET"; exit 1; }
  echo "credentials: read from environment"
fi

# Fingerprints, never the values. This repo is public and the operator's terminal scrollback is part
# of it; the hash is enough to prove a rotation actually took effect.
echo "  client_id:   $CID"
echo "  client_secret sha256:$(printf '%s' "$CSEC" | sha256sum | cut -c1-12)"

# --- render --------------------------------------------------------------------------------------
render() {
  TEMPLATE="$TEMPLATE" STAGE_BP="$STAGE_BP" CID="$CID" CSEC="$CSEC" REPO="$REPO" python3 - <<'PY'
import os, re, sys, yaml
env = os.environ
tpl = open(env["TEMPLATE"]).read()
for ph in ("${GOOGLE_CLIENT_ID}", "${GOOGLE_CLIENT_SECRET}"):
    if ph not in tpl:
        sys.exit(f"FAIL: {ph} not found in {env['TEMPLATE']} - template and script disagree")
rendered = (tpl.replace("${GOOGLE_CLIENT_ID}", env["CID"])
              .replace("${GOOGLE_CLIENT_SECRET}", env["CSEC"]))
# Exact-shape check, not a substring test: the template's header prose mentions ${...} while
# explaining the mechanism, and a crude check fires on its own documentation.
leftover = re.findall(r"\$\{[A-Z_]+\}", rendered)
if leftover:
    sys.exit(f"FAIL: unsubstituted placeholder(s): {leftover}")
# Must parse the way authentik will parse it. Plain safe_load raises on !Find, so the guard would
# reject valid input - the shared loader tolerates the tag, same helper as tools/oidc-check.py.
sys.path.insert(0, os.path.join(env["REPO"], "tools"))
from sopsload import load_tolerating_tags  # noqa: E402
doc = load_tolerating_tags(rendered)

# States are an enum, not prose: blueprints/v1/common.py defines exactly
# {absent, present, created, must_created}. `state: update` reads like the obvious verb for "patch this
# existing object", is not a state, and fails the WHOLE blueprint - every entry, not just the bad one -
# which is how a correct source definition silently stopped applying. Cheaper to check here than to
# discover it in a worker log that does not exist.
VALID_STATES = {"absent", "present", "created", "must_created"}
for i, entry in enumerate(doc.get("entries") or []):
    st = entry.get("state", "present")
    if st not in VALID_STATES:
        sys.exit(f"FAIL: entry {i} ({entry.get('model')}) has state {st!r}; "
                 f"authentik accepts exactly {sorted(VALID_STATES)} - and an invalid state rejects "
                 f"the entire blueprint, not just this entry")

with open(env["STAGE_BP"], "w") as fh:
    yaml.safe_dump({
        "apiVersion": "v1", "kind": "Secret",
        "metadata": {"name": "authentik-google-blueprint", "namespace": "auth"},
        "type": "Opaque",
        # Key name matters: the chart mounts this Secret into /blueprints/mounted/<secret>/<key>,
        # and only *.yaml is discovered.
        "stringData": {"google.yaml": rendered},
    }, fh, sort_keys=False, width=10**6)
PY
}

render
sops --encrypt --in-place "$STAGE_BP"
mv "$STAGE_BP" "$BP_SECRET"

# --- prove it is actually encrypted ---------------------------------------------------------------
# The guard is on the plaintext, not on the presence of ENC[: a file that carries ENC[ AND a stray
# plaintext copy of the secret is the failure mode that looks green.
if grep -qF "$CSEC" "$BP_SECRET"; then
  rm -f "$BP_SECRET"
  echo "FAIL: rendered Secret still contains the plaintext client secret"; exit 1
fi
grep -q "ENC\[" "$BP_SECRET" || { echo "FAIL: no ENC[ found - sops did not encrypt"; exit 1; }
chmod 600 "$BP_SECRET"

echo "wrote $BP_SECRET"
echo "next: add it to apply/10-secrets/kustomization.yaml and to blueprints.secrets in"
echo "      apply/50-apps/auth/authentik.yaml, then 'make check'."
