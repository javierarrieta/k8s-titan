#!/usr/bin/env bash
# Create everything coder needs that this repo cannot simply commit: the database password and the
# OIDC client, each written to every place it has to appear.
#
# RUN IT, DON'T READ IT INTO A SHELL. Same reason as rotate-s3-backup-key.sh: the operator's login
# shell is fish, and `read -rs -p`, heredocs and `[[ =~ ]]` all mean something different - or
# nothing - there. The plan for this task wrote the staging step as a fish heredoc, and fish has no
# heredocs at all, so copy-pasting the plan would have failed in a way that looks like a broken repo
# rather than a broken paste.
#
# NOTHING IS PROMPTED ANYMORE, AND THAT IS THE POINT.
# The original design had you create the OIDC application in authentik's UI and paste the client in.
# authentik takes that configuration as a blueprint - see
# authentik/blueprints-coder.yaml for why, and what is not proven about it - so the client
# is generated here and handed to both sides. No UI click, nothing to paste into a chat transcript,
# and a rebuilt authentik gets coder's client back from git instead of from someone's memory.
#
# Why a script at all: three files must agree. coder takes the DB password inline in a URL,
# CloudNativePG takes it in a basic-auth Secret, and authentik's blueprint takes the OIDC client
# the same way coder does. Hand-editing them is how they drift, and the drift surfaces as an
# authentication failure that reads like a database or a coder bug. `make db-url-check` and
# `make oidc-check` enforce the agreement afterwards; this makes it awkward to get wrong now.
#
# Nothing prints a value. What you see is a truncated SHA-256 per secret, so a re-run can be
# compared against the last one without the secret being on screen.
set -euo pipefail

REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$REPO"

DB_SECRET=apply/10-secrets/coder-db-credentials.yaml
APP_SECRET=apply/10-secrets/coder-secrets.yaml
BP_SECRET=apply/10-secrets/authentik-coder-blueprint.yaml
TEMPLATE=authentik/blueprints-coder.yaml
STAGE_DB=apply/10-secrets/.staging.coder-db-credentials.yaml
STAGE_APP=apply/10-secrets/.staging.coder.yaml
STAGE_BP=apply/10-secrets/.staging.authentik-coder-blueprint.yaml
KEY=${SOPS_AGE_KEY_FILE:-$HOME/.config/sops/age/titan-k8s-key.txt}

# Never leave plaintext behind, whatever fails. All three staging paths are git-ignored by name
# (.gitignore: apply/10-secrets/.staging.*.yaml), and they sit under apply/10-secrets/ because
# sops picks recipients from the file's own path, not from your intent.
trap 'rm -f "$STAGE_DB" "$STAGE_APP" "$STAGE_BP"' EXIT

for tool in sops python3; do
  command -v "$tool" >/dev/null || { echo "FAIL: $tool not on PATH"; exit 1; }
done
[ -f "$KEY" ] || { echo "FAIL: no age key at $KEY - set SOPS_AGE_KEY_FILE"; exit 1; }
export SOPS_AGE_KEY_FILE="$KEY"
# python3 rather than openssl for randomness: openssl is not on PATH in every environment this runs
# in (verified absent here), and sops already forces python3 to exist.
[ -f "$TEMPLATE" ] || { echo "FAIL: $TEMPLATE missing - nothing to render"; exit 1; }

existing=()
for f in "$DB_SECRET" "$APP_SECRET" "$BP_SECRET"; do
  [ -f "$f" ] && existing+=("$f")
done
if [ ${#existing[@]} -gt 0 ]; then
  echo "FAIL: these already exist and would be replaced with new credentials:"
  printf '  %s\n' "${existing[@]}"
  echo "That means coder would be pointing at a database password and an OIDC client that no longer"
  echo "exist. If that is what you want, re-run with FORCE=1 and expect coder to need a restart."
  [ "${FORCE:-0}" = "1" ] || exit 1
  echo "FORCE=1 set - overwriting."
fi

# --- generate -------------------------------------------------------------------------------
# Hex for the DB password on purpose: it goes inline inside a postgres:// URL, and '@', '/', ':' or
# '%' would make that URL ambiguous to anything parsing it without percent-encoding - including
# make db-url-check, which parses it with urllib rather than eyeballing it.
DBPASS=$(python3 -c 'import secrets; print(secrets.token_hex(16))')
# A UUID-shaped client ID, matching what authentik's own generate_id produces, so a client created
# by hand and one created by this script are indistinguishable.
CID=$(python3 -c 'import uuid; print(uuid.uuid4())')
CSEC=$(python3 -c 'import secrets; print(secrets.token_hex(32))')

# --- render and write ------------------------------------------------------------------------
# The blueprint Secret is built in python, not with a heredoc: the blueprint is multi-line YAML
# going into a YAML string value, and hand-rolled indentation is how you ship a Secret that parses
# as one opaque blob instead of a document.
render() {
  TEMPLATE="$TEMPLATE" DB_SECRET="$DB_SECRET" APP_SECRET="$APP_SECRET" BP_SECRET="$BP_SECRET" \
  STAGE_DB="$STAGE_DB" STAGE_APP="$STAGE_APP" STAGE_BP="$STAGE_BP" \
  DBPASS="$DBPASS" CID="$CID" CSEC="$CSEC" python3 - <<'PY'
import os, re, sys, yaml

env = os.environ
tpl = open(env["TEMPLATE"]).read()
for ph in ("${CODER_OIDC_CLIENT_ID}", "${CODER_OIDC_CLIENT_SECRET}"):
    if ph not in tpl:
        sys.exit(f"FAIL: {ph} not found in {env['TEMPLATE']} - the template and this script disagree")

# Substitution is exact string replacement, and nothing else: whatever a reviewer reads in the
# template is byte-for-byte what authentik applies, apart from these two values. make oidc-check
# re-derives the same substitution and fails if the artifact differs.
rendered = (tpl.replace("${CODER_OIDC_CLIENT_ID}", env["CID"])
              .replace("${CODER_OIDC_CLIENT_SECRET}", env["CSEC"]))
# Same pattern the gate uses, not a bare '"${" in rendered': this template's own header comment
# mentions "${...}" in prose while explaining the mechanism, and a crude substring check fails on
# it. A guard that fires on its own documentation is a guard that gets deleted.
leftover = re.findall(r"\$\{[A-Z_]+\}", rendered)
if leftover:
    sys.exit(f"FAIL: unsubstituted placeholder(s) remain in the rendered blueprint: {leftover}")
yaml.safe_load(rendered)  # refuse to ship a blueprint that will not parse

def dump(path, obj):
    with open(path, "w") as fh:
        yaml.safe_dump(obj, fh, sort_keys=False, width=10**6)

dump(env["STAGE_DB"], {
    "apiVersion": "v1", "kind": "Secret",
    "metadata": {"name": "coder-db-credentials", "namespace": "databases",
                 "labels": {"cnpg.io/reload": "true"}},
    "type": "kubernetes.io/basic-auth",
    "stringData": {"username": "coder", "password": env["DBPASS"]},
})
dump(env["STAGE_APP"], {
    "apiVersion": "v1", "kind": "Secret",
    "metadata": {"name": "coder-secrets", "namespace": "coder"},
    "type": "Opaque",
    "stringData": {
        "db-url": ("postgres://coder:" + env["DBPASS"] +
                   "@postgres-rw.databases.svc.cluster.local:5432/coder?sslmode=require"),
        "oidc-client-id": env["CID"],
        "oidc-client-secret": env["CSEC"],
    },
})
dump(env["STAGE_BP"], {
    "apiVersion": "v1", "kind": "Secret",
    "metadata": {"name": "authentik-coder-blueprint", "namespace": "auth"},
    "type": "Opaque",
    # The worker only picks up keys ending in .yaml, so the key name is part of the contract.
    "stringData": {"coder.yaml": rendered},
})
PY
}
render
unset DBPASS CID CSEC

for f in "$STAGE_DB" "$STAGE_APP" "$STAGE_BP"; do sops --encrypt --in-place "$f"; done
mv "$STAGE_DB"  "$DB_SECRET"
mv "$STAGE_APP" "$APP_SECRET"
mv "$STAGE_BP"  "$BP_SECRET"

echo "== written (fingerprints only)"
sops -d "$DB_SECRET" | python3 -c '
import sys, yaml, hashlib
sd = yaml.safe_load(sys.stdin.read())["stringData"]
print("  coder-db-credentials       username=" + sd["username"] +
      "  password sha256:" + hashlib.sha256(sd["password"].encode()).hexdigest()[:12])'
sops -d "$APP_SECRET" | python3 -c '
import sys, yaml, hashlib, urllib.parse
sd = yaml.safe_load(sys.stdin.read())["stringData"]
u = urllib.parse.urlparse(sd["db-url"])
print("  coder-secrets              db-url user=" + urllib.parse.unquote(u.username or "") +
      " host=" + (u.hostname or "") + " db=" + u.path.lstrip("/") +
      "  password sha256:" + hashlib.sha256(urllib.parse.unquote(u.password or "").encode()).hexdigest()[:12])
print("                             oidc-client-id " + sd["oidc-client-id"][:8] +
      "...  secret sha256:" + hashlib.sha256(sd["oidc-client-secret"].encode()).hexdigest()[:12])'
sops -d "$BP_SECRET" | python3 -c '
import sys, yaml, hashlib
sd = yaml.safe_load(sys.stdin.read())["stringData"]
print("  authentik-coder-blueprint  coder.yaml " + str(len(sd["coder.yaml"])) + " bytes, sha256:" +
      hashlib.sha256(sd["coder.yaml"].encode()).hexdigest()[:12])'

cat <<'EOF'

Next, in this order:

  1. List all three in apply/10-secrets/kustomization.yaml, and mount the blueprint by adding
     blueprints.secrets: [authentik-coder-blueprint] to spec.values in apply/50-apps/auth/authentik.yaml.
     An unlisted Secret builds fine and is silently never applied; an unmounted blueprint is the
     same trap one layer down. `make secrets-placement` and `make oidc-check` are the two gates
     that catch them, and both only exist because they were easy to fall into.
  2. git add apply/10-secrets/coder-secrets.yaml apply/10-secrets/coder-db-credentials.yaml \
             apply/10-secrets/authentik-coder-blueprint.yaml
  3. make check
  4. commit, merge, let Flux apply. Then prove it actually took:
       kubectl -n auth logs deploy/authentik-worker --since=10m | grep -i blueprint
       kubectl -n auth get secret authentik-coder-blueprint
     A Secret that applied and a blueprint that was *applied by the worker* are different facts.
EOF
