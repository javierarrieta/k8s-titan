#!/usr/bin/env bash
# Mint everything open-webui needs and write it to the three places it has to appear.
#
# RUN IT, DON'T READ IT INTO A SHELL. The operator's login shell is fish, which has no heredocs and no
# `read -rs -p`; this file's bash-isms are deliberate and the shebang is the interpreter.
#
# WHY ONE SCRIPT FOR FOUR VALUES
# The DB password exists twice (CNPG's DatabaseRole in `databases`, and open-webui's DATABASE_URL in
# `open-webui`) and the OIDC client exists twice (authentik's blueprint, open-webui's env). Minting all
# of it in one process is the only way "they agree" is a property of the code rather than of the
# operator's attention. `make db-url-check` and `make open-webui-oidc-check` then prove it from the
# tree instead of trusting it.
#
# WEBUI_SECRET_KEY IS HERE TOO, and it is the one with a rule attached: v0.12.3 refuses to boot
# without it (env.py:786), and start.sh otherwise generates one into /app/backend/.webui_secret_key —
# container-local, so it dies with every pod and orphans every stored OAuth token. Casa lives with that
# bug; see spec §6. Rotating this value invalidates every session and every stored OAuth token, so it is
# rotated deliberately and never as a side effect of touching the OIDC client.
#
# Nothing prints a value. What you see is a truncated SHA-256 per file.
set -euo pipefail

REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$REPO"

TEMPLATE=authentik/blueprints-open-webui.yaml
BP_SECRET=apply/10-secrets/authentik-open-webui-blueprint.yaml
DB_SECRET=apply/10-secrets/open-webui-db-credentials.yaml
APP_SECRET=apply/10-secrets/open-webui-secrets.yaml
STAGE_BP=apply/10-secrets/.staging.authentik-open-webui-blueprint.yaml
STAGE_DB=apply/10-secrets/.staging.open-webui-db-credentials.yaml
STAGE_APP=apply/10-secrets/.staging.open-webui-secrets.yaml
KEY=${SOPS_AGE_KEY_FILE:-$HOME/.config/sops/age/keys.txt}

# Never leave plaintext behind, whatever fails. The staging paths are git-ignored by name
# (apply/10-secrets/.staging.*.yaml) and sit under apply/10-secrets/ because sops picks its
# recipients from the file's own path, not from your intent.
trap 'rm -f "$STAGE_BP" "$STAGE_DB" "$STAGE_APP"' EXIT

for tool in sops python3; do
  command -v "$tool" >/dev/null || { echo "FAIL: $tool not on PATH"; exit 1; }
done
[ -f "$KEY" ] || { echo "FAIL: no age key at $KEY - set SOPS_AGE_KEY_FILE to the file holding the titan-k8s private key"; exit 1; }
export SOPS_AGE_KEY_FILE="$KEY"
[ -f "$TEMPLATE" ] || { echo "FAIL: $TEMPLATE missing - nothing to render"; exit 1; }

existing=()
for f in "$BP_SECRET" "$DB_SECRET" "$APP_SECRET"; do
  [ -f "$f" ] && existing+=("$f")
done
if [ ${#existing[@]} -gt 0 ]; then
  echo "FAIL: these already exist and would be replaced with NEW values:"
  printf '  %s\n' "${existing[@]}"
  echo "open-webui would then present a client and a password authentik and CNPG do not recognise, and"
  echo "rotating WEBUI_SECRET_KEY would orphan every session and stored OAuth token. If that is what"
  echo "you want, re-run with FORCE=1."
  [ "${FORCE:-0}" = "1" ] || exit 1
fi

CID=$(python3 -c 'import uuid; print(uuid.uuid4())')
CSEC=$(python3 -c 'import secrets; print(secrets.token_hex(32))')
DBPW=$(python3 -c 'import secrets; print(secrets.token_urlsafe(24))')
WEBKEY=$(python3 -c 'import secrets; print(secrets.token_urlsafe(48))')

TEMPLATE="$TEMPLATE" STAGE_BP="$STAGE_BP" STAGE_DB="$STAGE_DB" STAGE_APP="$STAGE_APP" \
CID="$CID" CSEC="$CSEC" DBPW="$DBPW" WEBKEY="$WEBKEY" python3 - <<'PY'
import os, re, sys, yaml

env = os.environ
tpl = open(env["TEMPLATE"]).read()
for ph in ("${OPEN_WEBUI_OIDC_CLIENT_ID}", "${OPEN_WEBUI_OIDC_CLIENT_SECRET}"):
    if ph not in tpl:
        sys.exit(f"FAIL: {ph} not found in {env['TEMPLATE']} - template and script disagree")

# Exact string substitution and nothing else: what a reviewer reads in the template is byte-for-byte
# what authentik applies, apart from these two values.
rendered = (tpl.replace("${OPEN_WEBUI_OIDC_CLIENT_ID}", env["CID"])
              .replace("${OPEN_WEBUI_OIDC_CLIENT_SECRET}", env["CSEC"]))
leftover = re.findall(r"\$\{[A-Z_]+\}", rendered)
if leftover:
    sys.exit(f"FAIL: unsubstituted placeholder(s) remain: {leftover}")

def dump(path, obj):
    with open(path, "w") as fh:
        yaml.safe_dump(obj, fh, sort_keys=False, width=100)

dump(env["STAGE_BP"], {
    "apiVersion": "v1", "kind": "Secret",
    "metadata": {"name": "authentik-open-webui-blueprint", "namespace": "auth"},
    "type": "Opaque",
    # The worker only picks up keys ending in .yaml, so the key name is part of the contract.
    "stringData": {"open-webui.yaml": rendered},
})

# CNPG's DatabaseRole reads a kubernetes.io/basic-auth Secret whose `username` MUST equal the role
# name, and the cnpg.io/reload label belongs on THIS Secret, not on the DatabaseRole, where it would
# do nothing.
dump(env["STAGE_DB"], {
    "apiVersion": "v1", "kind": "Secret",
    "metadata": {
        "name": "open-webui-db-credentials", "namespace": "databases",
        "labels": {"cnpg.io/reload": "true"},
    },
    "type": "kubernetes.io/basic-auth",
    "stringData": {"username": "open_webui", "password": env["DBPW"]},
})

# open-webui's own copy. token_urlsafe/token_hex are URL-safe by construction, so DATABASE_URL needs
# no percent-encoding step - which is the usual way an inline password breaks.
dump(env["STAGE_APP"], {
    "apiVersion": "v1", "kind": "Secret",
    "metadata": {"name": "open-webui-secrets", "namespace": "open-webui"},
    "type": "Opaque",
    "stringData": {
        "DATABASE_URL": f"postgresql://open_webui:{env['DBPW']}@postgres-rw.databases.svc.cluster.local:5432/open_webui",
        "WEBUI_SECRET_KEY": env["WEBKEY"],
        "OAUTH_CLIENT_ID": env["CID"],
        "OAUTH_CLIENT_SECRET": env["CSEC"],
    },
})
PY

for f in "$STAGE_BP" "$STAGE_DB" "$STAGE_APP"; do
  sops --encrypt --in-place "$f"
  if [ "$f" = "$STAGE_BP" ]; then dest=$BP_SECRET
  elif [ "$f" = "$STAGE_DB" ]; then dest=$DB_SECRET
  else dest=$APP_SECRET; fi
  mv "$f" "$dest"
  echo "wrote $dest  (fingerprint $(python3 -c "import hashlib,sys;print(hashlib.sha256(open(sys.argv[1],'rb').read()).hexdigest()[:12])" "$dest"))"
done

cat <<'DONE'

Done. Three files, four values, all encrypted.

Still to do, in order:
  1. make db-url-check open-webui-oidc-check   (once their gates exist) proves the copies agree.
  2. Merge, then force the blueprint from the UI or wait for the worker's hourly discovery.
     Mounting is not applying - docs/authentik-runbook.md §5.
  3. The FIRST authentik user to sign in becomes open-webui admin, whatever the env says
     (utils/oauth.py:1598-1607). Do that deliberately, and record which /oauth/oidc/... callback
     path appears on the wire so the blueprint can be narrowed to it.
DONE
