#!/usr/bin/env bash
# Create Grafana's OIDC client and write it to both places it has to appear: authentik's blueprint
# and Grafana's own environment.
#
# RUN IT, DON'T READ IT INTO A SHELL. The operator's login shell is fish, which has no heredocs and no
# `read -rs -p`; this file's bash-isms are deliberate and the shebang is the interpreter.
#
# WHY A SCRIPT AND NOT A UI CLICK
# The same reason setup-coder-secrets.sh exists. authentik takes this configuration as a blueprint, so
# generating the client here and handing it to both sides means a rebuilt authentik gets Grafana's
# client back from git rather than from someone's memory, and nothing is ever pasted into a chat
# transcript. It also means there is no window where authentik has a client Grafana does not know about.
#
# TWO FILES, ONE CREDENTIAL — which is the whole reason `make grafana-oidc-check` exists. Grafana
# reads the pair from tesla-grafana-oidc; authentik reads it from the rendered blueprint. If they
# disagree, every login fails with an OIDC error that reads like a Grafana bug.
#
# Nothing prints a value. What you see is a truncated SHA-256 per secret, so a re-run can be compared
# against the last one without the secret being on screen.
set -euo pipefail

REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$REPO"

TEMPLATE=authentik/blueprints-grafana.yaml
BP_SECRET=apply/10-secrets/authentik-grafana-blueprint.yaml
APP_SECRET=apply/10-secrets/tesla-grafana-oidc.yaml
STAGE_BP=apply/10-secrets/.staging.authentik-grafana-blueprint.yaml
STAGE_APP=apply/10-secrets/.staging.grafana-oidc.yaml
KEY=${SOPS_AGE_KEY_FILE:-$HOME/.config/sops/age/keys.txt}
# The default is sops' own default location, not a repo-specific filename: this workspace decrypts
# with keys.txt, and a gate that insists on a path nobody uses fails for the wrong reason. If you do
# keep the key elsewhere, set SOPS_AGE_KEY_FILE and it is honoured.

# Never leave plaintext behind, whatever fails. Both staging paths are git-ignored by name
# (apply/10-secrets/.staging.*.yaml) and sit under apply/10-secrets/ because sops picks its
# recipients from the file's own path, not from your intent.
trap 'rm -f "$STAGE_BP" "$STAGE_APP"' EXIT

for tool in sops python3; do
  command -v "$tool" >/dev/null || { echo "FAIL: $tool not on PATH"; exit 1; }
done
[ -f "$KEY" ] || { echo "FAIL: no age key at $KEY - set SOPS_AGE_KEY_FILE to the file that holds the titan-k8s private key"; exit 1; }
export SOPS_AGE_KEY_FILE="$KEY"
[ -f "$TEMPLATE" ] || { echo "FAIL: $TEMPLATE missing - nothing to render"; exit 1; }

existing=()
for f in "$BP_SECRET" "$APP_SECRET"; do
  [ -f "$f" ] && existing+=("$f")
done
if [ ${#existing[@]} -gt 0 ]; then
  echo "FAIL: these already exist and would be replaced with a NEW client:"
  printf '  %s\n' "${existing[@]}"
  echo "Grafana would then be presenting a client authentik no longer recognises, and every OIDC login"
  echo "would fail until both sides are re-rendered together. If that is what you want, re-run with"
  echo "FORCE=1."
  [ "${FORCE:-0}" = "1" ] || exit 1
fi

CID=$(python3 -c 'import uuid; print(uuid.uuid4())')
CSEC=$(python3 -c 'import secrets; print(secrets.token_hex(32))')

TEMPLATE="$TEMPLATE" STAGE_BP="$STAGE_BP" STAGE_APP="$STAGE_APP" CID="$CID" CSEC="$CSEC" python3 - <<'PY'
import os, re, sys, yaml

env = os.environ
tpl = open(env["TEMPLATE"]).read()
for ph in ("${GRAFANA_OIDC_CLIENT_ID}", "${GRAFANA_OIDC_CLIENT_SECRET}"):
    if ph not in tpl:
        sys.exit(f"FAIL: {ph} not found in {env['TEMPLATE']} - the template and this script disagree")

# Exact string substitution and nothing else: what a reviewer reads in the template is byte-for-byte
# what authentik applies, apart from these two values. make grafana-oidc-check re-derives the same
# substitution and fails if the artifact differs.
rendered = (tpl.replace("${GRAFANA_OIDC_CLIENT_ID}", env["CID"])
              .replace("${GRAFANA_OIDC_CLIENT_SECRET}", env["CSEC"]))
# The template's own header prose mentions "${...}" while explaining the mechanism, so a crude
# substring check fires on its own documentation. Match the placeholder shape instead.
leftover = re.findall(r"\$\{[A-Z_]+\}", rendered)
if leftover:
    sys.exit(f"FAIL: unsubstituted placeholder(s) remain in the rendered blueprint: {leftover}")

def dump(path, obj):
    with open(path, "w") as fh:
        yaml.safe_dump(obj, fh, sort_keys=False, width=100)

dump(env["STAGE_BP"], {
    "apiVersion": "v1", "kind": "Secret",
    "metadata": {"name": "authentik-grafana-blueprint", "namespace": "auth"},
    "type": "Opaque",
    # The worker only picks up keys ending in .yaml, so the key name is part of the contract.
    "stringData": {"grafana.yaml": rendered},
})

# Grafana's copy. Names are the config keys it reads, so envFrom injects them with no mapping and no
# chance of a typo'd alias between the Secret and the Deployment.
dump(env["STAGE_APP"], {
    "apiVersion": "v1", "kind": "Secret",
    "metadata": {"name": "tesla-grafana-oidc", "namespace": "apps"},
    "type": "Opaque",
    "stringData": {
        "GF_AUTH_GENERIC_OAUTH_CLIENT_ID": env["CID"],
        "GF_AUTH_GENERIC_OAUTH_CLIENT_SECRET": env["CSEC"],
    },
})
PY

for f in "$STAGE_BP" "$STAGE_APP"; do
  sops --encrypt --in-place "$f"
  dest=$([ "$f" = "$STAGE_BP" ] && echo "$BP_SECRET" || echo "$APP_SECRET")
  mv "$f" "$dest"
  echo "wrote $dest  (fingerprint $(python3 -c "import hashlib,sys;print(hashlib.sha256(open(sys.argv[1],'rb').read()).hexdigest()[:12])" "$dest"))"
done

cat <<'DONE'

Done. Two files, one credential, both encrypted.

Still to do, in order:
  1. make grafana-oidc-check     proves the two copies and the mount agree before anything ships.
  2. Merge, and let the authentik worker apply the blueprint (hourly, or force it from the UI).
     Grafana's OIDC config arrives in the same commit, so between those two moments the login page
     offers a provider whose client authentik does not have yet — harmless, it just fails to log in.
  3. Sign in with authentik once and confirm the role you expected, THEN consider whether the local
     admin account is still needed. GF_AUTH_BASIC_ENABLED stays true in this repo on purpose: it is
     the way back in if the OIDC config is ever wrong.
DONE
