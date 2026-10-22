#!/usr/bin/env bash
# Mint everything Mealie needs and write it to the three places it has to appear.
#
# RUN IT, DON'T READ IT INTO A SHELL. The operator's login shell is fish, which has no heredocs and no
# `read -rs -p`; this file's bash-isms are deliberate and the shebang is the interpreter.
#
# WHY ONE SCRIPT FOR THREE VALUES
# The DB password exists twice (CNPG's DatabaseRole in `databases`, and Mealie's POSTGRES_PASSWORD in
# namespace `mealie`) and the OIDC client exists twice (authentik's blueprint, Mealie's env). Minting
# all of it in one process is the only way "they agree" is a property of the code rather than of the
# operator's attention. `make mealie-check` then proves it from the tree instead of trusting it — and
# it has to, because Mealie takes its database as POSTGRES_* rather than a single DATABASE_URL, so the
# generic `make db-url-check` never looks at this app at all.
#
# NOTHING PRINTS A VALUE. What you see is a truncated SHA-256 per file.
#
# Unlike scripts/setup-open-webui-secrets.sh there is no fourth value here. open-webui needs a
# WEBUI_SECRET_KEY because v0.12.3 refuses to boot without one; Mealie has no equivalent session-signing
# secret to pre-seed — it signs its own tokens with keys it holds in Postgres.
set -euo pipefail

REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$REPO"

TEMPLATE=authentik/blueprints-mealie.yaml
BP_SECRET=apply/10-secrets/authentik-mealie-blueprint.yaml
DB_SECRET=apply/10-secrets/mealie-db-credentials.yaml
APP_SECRET=apply/10-secrets/mealie-secrets.yaml
STAGE_BP=apply/10-secrets/.staging.authentik-mealie-blueprint.yaml
STAGE_DB=apply/10-secrets/.staging.mealie-db-credentials.yaml
STAGE_APP=apply/10-secrets/.staging.mealie-secrets.yaml
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
  echo "Mealie would then present a client and a password authentik and CNPG do not recognise. If that"
  echo "is what you want, re-run with FORCE=1 and rotate the OIDC client in the same change."
  [ "${FORCE:-0}" = "1" ] || exit 1
fi

CID=$(python3 -c 'import uuid; print(uuid.uuid4())')
CSEC=$(python3 -c 'import secrets; print(secrets.token_hex(32))')
DBPW=$(python3 -c 'import secrets; print(secrets.token_urlsafe(24))')

TEMPLATE="$TEMPLATE" STAGE_BP="$STAGE_BP" STAGE_DB="$STAGE_DB" STAGE_APP="$STAGE_APP" \
CID="$CID" CSEC="$CSEC" DBPW="$DBPW" python3 - <<'PY'
import os, re, sys, yaml

env = os.environ
tpl = open(env["TEMPLATE"]).read()
for ph in ("${MEALIE_OIDC_CLIENT_ID}", "${MEALIE_OIDC_CLIENT_SECRET}"):
    if ph not in tpl:
        sys.exit(f"FAIL: {ph} not found in {env['TEMPLATE']} - template and script disagree")

# Exact string substitution and nothing else: what a reviewer reads in the template is byte-for-byte
# what authentik applies, apart from these two values.
rendered = (tpl.replace("${MEALIE_OIDC_CLIENT_ID}", env["CID"])
              .replace("${MEALIE_OIDC_CLIENT_SECRET}", env["CSEC"]))
leftover = re.findall(r"\$\{[A-Z_]+\}", rendered)
if leftover:
    sys.exit(f"FAIL: unsubstituted placeholder(s) remain: {leftover}")

def dump(path, obj):
    with open(path, "w") as fh:
        yaml.safe_dump(obj, fh, sort_keys=False, width=100)

dump(env["STAGE_BP"], {
    "apiVersion": "v1", "kind": "Secret",
    "metadata": {"name": "authentik-mealie-blueprint", "namespace": "auth"},
    "type": "Opaque",
    # The worker only picks up keys ending in .yaml, so the key name is part of the contract.
    "stringData": {"mealie.yaml": rendered},
})

# CNPG's DatabaseRole reads a kubernetes.io/basic-auth Secret whose `username` MUST equal the role
# name, and the cnpg.io/reload label belongs on THIS Secret, not on the DatabaseRole, where it would
# do nothing.
dump(env["STAGE_DB"], {
    "apiVersion": "v1", "kind": "Secret",
    "metadata": {
        "name": "mealie-db-credentials", "namespace": "databases",
        "labels": {"cnpg.io/reload": "true"},
    },
    "type": "kubernetes.io/basic-auth",
    "stringData": {"username": "mealie", "password": env["DBPW"]},
})

# Mealie's own copy. Only the three values that are actually credentials live here; the host, port,
# database name and engine are non-secret and sit in the Deployment where a reviewer can read them.
# token_urlsafe/token_hex are URL-safe by construction, so Mealie's own percent-encoding step
# (urlparse.quote in mealie/core/settings/db_providers.py) has nothing to escape.
dump(env["STAGE_APP"], {
    "apiVersion": "v1", "kind": "Secret",
    "metadata": {"name": "mealie-secrets", "namespace": "mealie"},
    "type": "Opaque",
    "stringData": {
        "POSTGRES_PASSWORD": env["DBPW"],
        "OIDC_CLIENT_ID": env["CID"],
        "OIDC_CLIENT_SECRET": env["CSEC"],
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

Done. Three files, three values, all encrypted.

Still to do, in order:
  1. make mealie-check            proves the copies agree and the blueprint is mounted.
  2. Merge, then force the blueprint from the UI or wait for the worker's hourly discovery.
     Mounting is not applying - docs/authentik-runbook.md §5.
  3. The FIRST authentik user to sign in becomes Mealie's owner. Do that deliberately.
  4. Mealie's AI recipe importer cannot be configured from git at all: the provider (base_url, key,
     model) is a row in Mealie's own Postgres, created in Group Settings -> AI. There is no env var
     for it — `grep -i openai mealie/core/settings/settings.py` on mealie-next returns nothing.
     See docs/superpowers/specs/2026-10-22-titan-mealie-design.md for what to type there.
DONE
