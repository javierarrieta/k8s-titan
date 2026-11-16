#!/usr/bin/env bash
# Mint everything Vikunja needs and write it to the places it has to appear.
#
# RUN IT, DON'T READ IT INTO A SHELL. The operator's login shell is fish, which has no heredocs and no
# `read -rs -p`; this file's bash-isms are deliberate and the shebang is the interpreter.
#
# WHY ONE SCRIPT FOR FOUR VALUES
# The DB password exists twice (CNPG's DatabaseRole in `databases`, and Vikunja's
# VIKUNJA_DATABASE_PASSWORD in namespace `vikunja`) and the OIDC client exists twice (authentik's
# blueprint, Vikunja's env). Minting all of it in one process is the only way "they agree" is a
# property of the code rather than of the operator's attention. `make vikunja-check` then proves it
# from the tree — and it has to, because Vikunja takes split VIKUNJA_DATABASE_* keys rather than a
# single DATABASE_URL, so the generic `make db-url-check` never looks at this app at all.
#
# WHY A FIFTH VALUE MEALIE DID NOT NEED
# VIKUNJA_SERVICE_SECRET signs every issued token. Unset, generateServiceSecretIfEmpty() in
# pkg/config/config.go mints a random one per boot and every already-issued token dies with the old
# process — with strategy: Recreate that is every deploy logging everyone out. Mealie signs its own
# tokens with keys held in Postgres and has no equivalent to pre-seed.
#
# WHY THE SMTP PAIR IS SUPPLIED AND NOT MINTED
# The mailbox already exists on mail.techdelivery.es and this script cannot create it — it lives in
# that box's config PVC, not in git. Passing a wrong password in here is worse than passing none:
# ENABLE_FAIL2BAN=1 on that box means a wrong credential from titan gets titan's address banned, and
# the symptom is "mail stopped working", not "auth failed". So the script takes the file, refuses a
# malformed one, and never prints what is in it.
#
# NOTHING PRINTS A VALUE. What you see is a truncated SHA-256 per file.
set -euo pipefail

REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$REPO"

TEMPLATE=authentik/blueprints-vikunja.yaml
BP_SECRET=apply/10-secrets/authentik-vikunja-blueprint.yaml
DB_SECRET=apply/10-secrets/vikunja-db-credentials.yaml
APP_SECRET=apply/10-secrets/vikunja-secrets.yaml
STAGE_BP=apply/10-secrets/.staging.authentik-vikunja-blueprint.yaml
STAGE_DB=apply/10-secrets/.staging.vikunja-db-credentials.yaml
STAGE_APP=apply/10-secrets/.staging.vikunja-secrets.yaml
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

# The mailbox. Two lines: address, then password. Blank lines and trailing whitespace are tolerated;
# anything else is a hard stop, because a mangled address is a MAIL FROM refusal later.
SMTP_FILE=${SMTP_FILE:?FAIL: set SMTP_FILE=/path/to/two-line-file (address on line 1, password on line 2)}
[ -f "$SMTP_FILE" ] || { echo "FAIL: SMTP_FILE=$SMTP_FILE does not exist"; exit 1; }
SMTP_USER=$(sed -n '1s/[[:space:]]*$//p' "$SMTP_FILE")
SMTP_PASS=$(sed -n '2s/[[:space:]]*$//p' "$SMTP_FILE")
[ -n "$SMTP_USER" ] && case "$SMTP_USER" in *@*) ;; *) echo "FAIL: line 1 of $SMTP_FILE is not an address"; exit 1;; esac
[ -n "$SMTP_PASS" ] || { echo "FAIL: line 2 of $SMTP_FILE is empty - no password"; exit 1; }
echo "smtp user: $SMTP_USER"

existing=()
for f in "$BP_SECRET" "$DB_SECRET" "$APP_SECRET"; do
  [ -f "$f" ] && existing+=("$f")
done
if [ ${#existing[@]} -gt 0 ]; then
  echo "FAIL: these already exist and would be replaced with NEW values:"
  printf '  %s\n' "${existing[@]}"
  echo "Vikunja would then present a client and a password authentik and CNPG do not recognise. If that"
  echo "is what you want, re-run with FORCE=1 and rotate the OIDC client in the same change."
  [ "${FORCE:-0}" = "1" ] || exit 1
fi

CID=$(python3 -c 'import uuid; print(uuid.uuid4())')
CSEC=$(python3 -c 'import secrets; print(secrets.token_hex(32))')
DBPW=$(python3 -c 'import secrets; print(secrets.token_urlsafe(24))')
SVSEC=$(python3 -c 'import secrets; print(secrets.token_hex(32))')

TEMPLATE="$TEMPLATE" STAGE_BP="$STAGE_BP" STAGE_DB="$STAGE_DB" STAGE_APP="$STAGE_APP" \
CID="$CID" CSEC="$CSEC" DBPW="$DBPW" SVSEC="$SVSEC" \
SMTP_USER="$SMTP_USER" SMTP_PASS="$SMTP_PASS" python3 - <<'PY'
import os, re, sys, yaml

env = os.environ
tpl = open(env["TEMPLATE"]).read()
for ph in ("${VIKUNJA_OIDC_CLIENT_ID}", "${VIKUNJA_OIDC_CLIENT_SECRET}"):
    if ph not in tpl:
        sys.exit(f"FAIL: {ph} not found in {env['TEMPLATE']} - template and script disagree")

# Exact string substitution and nothing else: what a reviewer reads in the template is byte-for-byte
# what authentik applies, apart from these two values.
rendered = (tpl.replace("${VIKUNJA_OIDC_CLIENT_ID}", env["CID"])
              .replace("${VIKUNJA_OIDC_CLIENT_SECRET}", env["CSEC"]))
leftover = re.findall(r"\$\{[A-Z_]+\}", rendered)
if leftover:
    sys.exit(f"FAIL: unsubstituted placeholder(s) remain: {leftover}")

def dump(path, obj):
    with open(path, "w") as fh:
        yaml.safe_dump(obj, fh, sort_keys=False, width=100)

dump(env["STAGE_BP"], {
    "apiVersion": "v1", "kind": "Secret",
    "metadata": {"name": "authentik-vikunja-blueprint", "namespace": "auth"},
    "type": "Opaque",
    # The worker only picks up keys ending in .yaml, so the key name is part of the contract.
    "stringData": {"vikunja.yaml": rendered},
})

# CNPG's DatabaseRole reads a kubernetes.io/basic-auth Secret whose `username` MUST equal the role
# name, and the cnpg.io/reload label belongs on THIS Secret, not on the DatabaseRole, where it would
# do nothing.
dump(env["STAGE_DB"], {
    "apiVersion": "v1", "kind": "Secret",
    "metadata": {
        "name": "vikunja-db-credentials", "namespace": "databases",
        "labels": {"cnpg.io/reload": "true"},
    },
    "type": "kubernetes.io/basic-auth",
    "stringData": {"username": "vikunja", "password": env["DBPW"]},
})

# Vikunja's own copy. Every key is named EXACTLY as Vikunja reads it, so the Deployment uses a plain
# envFrom with no aliasing — a typo'd key here is a dead variable, not a startup error, which is why
# the names are written out once, here, rather than mapped in two places.
#
# The provider key in those names is `authentik`: setConfigFromEnv() lowercases every underscore-
# separated segment, so AUTHENTIK in the env var becomes the provider id `authentik`, which is also
# the segment in the blueprint's redirect URI. A key containing an underscore would not survive that
# split at all.
dump(env["STAGE_APP"], {
    "apiVersion": "v1", "kind": "Secret",
    "metadata": {"name": "vikunja-secrets", "namespace": "vikunja"},
    "type": "Opaque",
    "stringData": {
        "VIKUNJA_SERVICE_SECRET": env["SVSEC"],
        "VIKUNJA_DATABASE_PASSWORD": env["DBPW"],
        "VIKUNJA_AUTH_OPENID_PROVIDERS_AUTHENTIK_CLIENTID": env["CID"],
        "VIKUNJA_AUTH_OPENID_PROVIDERS_AUTHENTIK_CLIENTSECRET": env["CSEC"],
        "VIKUNJA_MAILER_USERNAME": env["SMTP_USER"],
        "VIKUNJA_MAILER_PASSWORD": env["SMTP_PASS"],
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

Done. Three files, five values, all encrypted.

Still to do, in order:
  1. make vikunja-check            proves the copies agree and the blueprint is mounted.
  2. Merge, then force the blueprint with `ak apply_blueprint` rather than waiting on the worker's
     hourly discovery pass. Mounting is not applying - docs/authentik-runbook.md §5.
  3. Prove the SMTP credential ONCE. ENABLE_FAIL2BAN=1 on mail.techdelivery.es bans the source
     address after repeated failures, so this is one deliberate test, not a retry loop.
  4. The first authentik user to sign in is the one who sets up the task lists. There is no
     registration and no local password, so there is no second way in.
DONE
