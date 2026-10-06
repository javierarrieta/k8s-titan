#!/usr/bin/env bash
# Create the two coder Secrets this repo needs, in one go, with the DB password generated once.
#
# RUN IT, DON'T READ IT INTO A SHELL. Same reason as rotate-s3-backup-key.sh: the operator's
# login shell is fish, and `read -rs -p`, heredocs and `[[ =~ ]]` all mean something different -
# or nothing - there. The plan for this task wrote the staging step as a fish heredoc, and fish has
# no heredocs at all, so a copy-paste of the plan would have failed in a way that looks like a
# broken repo rather than a broken paste.
#
# Why a script and not two files you edit by hand: the same DB password has to appear in BOTH
# Secrets - once inline in coder-secrets/db-url for coder, once in coder-db-credentials for
# CloudNativePG to set. Editing two files by hand is how they drift, and the drift surfaces as an
# authentication failure that reads like a database problem. make db-url-check enforces the
# agreement afterwards; this script makes it impossible to get wrong in the first place.
#
# Nothing here prints a value. What you see is a truncated SHA-256 per secret, so a re-run can be
# compared against the last one without the secret being on screen.
set -euo pipefail

REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$REPO"

DB_SECRET=apply/10-secrets/coder-db-credentials.yaml
APP_SECRET=apply/10-secrets/coder-secrets.yaml
STAGE_DB=apply/10-secrets/.staging.coder-db-credentials.yaml
STAGE_APP=apply/10-secrets/.staging.coder.yaml
KEY=${SOPS_AGE_KEY_FILE:-$HOME/.config/sops/age/titan-k8s-key.txt}

# Never leave plaintext behind, whatever fails. Both staging paths are git-ignored by name
# (.gitignore: apply/10-secrets/.staging.*.yaml), and they sit under apply/10-secrets/ because
# sops picks recipients from the file's own path, not from your intent.
trap 'rm -f "$STAGE_DB" "$STAGE_APP"' EXIT

for tool in sops python3; do
  command -v "$tool" >/dev/null || { echo "FAIL: $tool not on PATH"; exit 1; }
done
[ -f "$KEY" ] || { echo "FAIL: no age key at $KEY - set SOPS_AGE_KEY_FILE"; exit 1; }
export SOPS_AGE_KEY_FILE="$KEY"

if [ -f "$DB_SECRET" ] || [ -f "$APP_SECRET" ]; then
  echo "FAIL: one of these already exists:"
  [ -f "$DB_SECRET" ]  && echo "  $DB_SECRET"
  [ -f "$APP_SECRET" ] && echo "  $APP_SECRET"
  echo "Re-running would replace live credentials. If that is what you want, run again with"
  echo "FORCE=1 - and then expect coder to need a restart, because the OIDC client and the"
  echo "database password both change underneath it."
  [ "${FORCE:-0}" = "1" ] || exit 1
  echo "FORCE=1 set - overwriting."
fi

# --- inputs -----------------------------------------------------------------------------------
# Authentik side first: create the Application `coder` and its OAuth2/OIDC Provider, then paste
# here. Issuer path is https://auth.titan.arrieta.eu/application/o/coder/ - the client ID must
# belong to THAT application, because the issuer path is derived from the application slug and a
# client from another application authenticates fine and then returns claims nothing maps.
read -rs -p "authentik OIDC client ID for application 'coder': " CID;    echo
read -rs -p "authentik OIDC client secret:                      " CSEC;  echo

# Guards BEFORE encrypting. An empty client secret encrypts perfectly, ships green through every
# offline gate, and fails at the first login attempt - which is three namespaces and one time zone
# away from the mistake. Same class as the two empty authentik passwords.
if [ -z "${CID//[[:space:]]/}" ] || [ "${#CID}" -lt 8 ]; then
  echo "FAIL: client ID looks empty or too short (got ${#CID} chars)"; exit 1
fi
if [ -z "${CSEC//[[:space:]]/}" ] || [ "${#CSEC}" -lt 16 ]; then
  echo "FAIL: client secret looks empty or too short (got ${#CSEC} chars)"; exit 1
fi
case "$CID$CSEC" in
  *[[:space:]]*) echo "FAIL: neither value may contain whitespace - both go into a YAML double-quoted scalar and a URL"; exit 1 ;;
  *'"'*|*'\\'*) echo "FAIL: neither value may contain a double quote or backslash - both are interpolated into a YAML double-quoted scalar, and an embedded quote would silently truncate the credential at apply time"; exit 1 ;;
esac

# Generated, not typed: this password only has to agree between two files this script writes, and
# a human-typed one is a human-typed one. Charset is hex on purpose - it goes inline inside a
# postgres:// URL, and '@', '/', ':' or '%' would make that URL ambiguous to anything parsing it
# without percent-encoding. make db-url-check parses it with urllib, so an unsafe charset would
# not merely look ugly, it would compare the wrong substring. python3 rather than openssl because
# openssl is not on PATH in every environment this runs in (verified: absent here), while sops
# already forces python3 to be present for the fingerprinting below.
DBPASS=$(python3 -c 'import secrets; print(secrets.token_hex(16))')

# --- write, encrypt, move ---------------------------------------------------------------------
cat > "$STAGE_DB" <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: coder-db-credentials
  namespace: databases
  labels:
    # On the Secret, not the DatabaseRole - that is where CNPG actually looks for it.
    cnpg.io/reload: "true"
type: kubernetes.io/basic-auth
stringData:
  username: coder
  password: $DBPASS
EOF

cat > "$STAGE_APP" <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: coder-secrets
  namespace: coder
type: Opaque
stringData:
  db-url: "postgres://coder:$DBPASS@postgres-rw.databases.svc.cluster.local:5432/coder?sslmode=require"
  oidc-client-id: "$CID"
  oidc-client-secret: "$CSEC"
EOF
unset DBPASS CID CSEC

sops --encrypt --in-place "$STAGE_DB"
sops --encrypt --in-place "$STAGE_APP"
mv "$STAGE_DB"  "$DB_SECRET"
mv "$STAGE_APP" "$APP_SECRET"

echo "== written (fingerprints only)"
sops -d "$DB_SECRET" | python3 -c '
import sys, yaml, hashlib
sd = yaml.safe_load(sys.stdin.read())["stringData"]
print("  coder-db-credentials  username=" + sd["username"] + "  password sha256:" + hashlib.sha256(sd["password"].encode()).hexdigest()[:12])'
sops -d "$APP_SECRET" | python3 -c '
import sys, yaml, hashlib, urllib.parse
sd = yaml.safe_load(sys.stdin.read())["stringData"]
u = urllib.parse.urlparse(sd["db-url"])
print("  coder-secrets         db-url user=" + urllib.parse.unquote(u.username or "") +
      " host=" + (u.hostname or "") + " db=" + u.path.lstrip("/") +
      "  password sha256:" + hashlib.sha256(urllib.parse.unquote(u.password or "").encode()).hexdigest()[:12])
print("                        oidc-client-id " + sd["oidc-client-id"][:8] + "...  secret sha256:" +
      hashlib.sha256(sd["oidc-client-secret"].encode()).hexdigest()[:12])'

cat <<'EOF'

Next, in this order:

  1. Add both files to apply/10-secrets/kustomization.yaml. An unlisted Secret builds fine and is
     silently never applied - `make secrets-placement` is the gate that catches it, but only after
     the files are listed as its own check input.
  2. git add apply/10-secrets/coder-secrets.yaml apply/10-secrets/coder-db-credentials.yaml
  3. make check
  4. commit, merge, let Flux apply. Then confirm CNPG created the role as LOGIN:
       kubectl -n databases get database coder -o wide
       kubectl -n databases get databaserole coder
     A role without login: true is the failure mode to look for, and it reads as an auth error.
EOF
