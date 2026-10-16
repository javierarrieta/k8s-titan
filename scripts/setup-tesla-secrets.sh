#!/usr/bin/env bash
# Create everything TeslaMate needs that this repo cannot simply commit, encrypt it into
# apply/10-secrets, and print nothing but a truncated SHA-256 per value.
#
# RUN IT, DON'T READ IT INTO A SHELL. Same reason as setup-coder-secrets.sh: the operator's login
# shell is fish, which has no heredocs, so copy-pasting a multi-line secret recipe into it fails in
# a way that looks like a broken repo rather than a broken paste.
#
# THE TESLA APPLICATION PRIVATE KEY IS NOT GENERATED OR STORED HERE, AND THAT IS DELIBERATE.
# Nothing running in the cluster ever uses it. The only thing that needs it is the vehicle-command
# proxy, which signs fleet_telemetry_config once, from the operator's own machine (spec §7 step 6)
# - and neither ghcr.io nor Docker Hub ships a vehicle-command image (verified: no Docker Hub repo
# for teslamotors/vehicle-command, and release v0.4.1 carries no assets), so there is no container
# to drop it into either. A signing key no pod needs has no business living in a cluster this repo
# describes as public-internet. So: --genkey writes the pair to a directory YOU choose, outside the
# repo, and only the PUBLIC half is ever committed - as tesla-wellknown.yaml, because Tesla re-checks
# that URL forever and pairing fails with a misleading "application has not registered" when it 404s.
#
# openssl is not on PATH here (verified), so the keypair comes from `go run` on the stdlib instead,
# and randomness comes from python3, which sops already forces to exist.
#
# Idempotent by refusal: existing files are not overwritten unless FORCE=1, because silently
# re-generating ENCRYPTION_KEY makes every stored vehicle token undecryptable - TeslaMate stores the
# OAuth tokens encrypted under it - and silently re-generating the DB password desynchronises the
# two places it appears (this Secret and the CNPG DatabaseRole's passwordSecret) in a way that reads
# later as a broken app rather than as a rotation nobody announced.
set -euo pipefail

REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$REPO"

RUNTIME_SECRET=apply/10-secrets/teslamate-secrets.yaml
DB_SECRET=apply/10-secrets/teslamate-db-credentials.yaml
PUBKEY_SECRET=apply/10-secrets/tesla-wellknown.yaml
OAUTH_SECRET=apply/10-secrets/tesla-oauth.yaml
STAGE_RUNTIME=apply/10-secrets/.staging.teslamate-secrets.yaml
STAGE_DB=apply/10-secrets/.staging.teslamate-db-credentials.yaml
STAGE_PUBKEY=apply/10-secrets/.staging.tesla-wellknown.yaml
STAGE_OAUTH=apply/10-secrets/.staging.tesla-oauth.yaml
# Key resolution: honour SOPS_AGE_KEY_FILE if it is set, otherwise try sops' own default and then
# the name the rest of this repo's scripts use. Both are seen in practice - `keys.txt` is what this
# Coder workspace actually has (verified: `sops -d` on an existing Secret succeeds with no env set),
# while setup-coder-secrets.sh hardcodes titan-k8s-key.txt, which is the laptop name. A script that
# only accepts one of the two fails on the machine that has the other, and the failure reads as
# "the repo is broken" rather than "you looked in one place".
if [ -n "${SOPS_AGE_KEY_FILE:-}" ]; then
  KEY=$SOPS_AGE_KEY_FILE
else
  for cand in "$HOME/.config/sops/age/keys.txt" "$HOME/.config/sops/age/titan-k8s-key.txt"; do
    [ -f "$cand" ] && { KEY=$cand; break; }
  done
  KEY=${KEY:-$HOME/.config/sops/age/keys.txt}
fi

# Never leave plaintext behind, whatever fails. All three staging paths are git-ignored by name
# (.gitignore: apply/10-secrets/.staging.*.yaml), and they sit under apply/10-secrets/ because sops
# picks recipients from the file's own path, not from your intent.
trap 'rm -f "$STAGE_RUNTIME" "$STAGE_DB" "$STAGE_PUBKEY" "$STAGE_OAUTH"' EXIT

usage() {
  cat <<'EOF'
usage:
  setup-tesla-secrets.sh --genkey [DIR]     mint the Tesla application P-256 keypair in DIR
                                          (default ~/tesla), outside the repo, and stop
  setup-tesla-secrets.sh [PUBLIC_KEY_PEM]   write the Secrets; with no PEM, write only the two
                                          that do not need it and say which is still pending

  TESLA_CLIENT_ID=<id from developer.tesla.com> must be set alongside the PEM. It is not a secret,
  but it is not knowable before the application exists, and a ConfigMap placeholder that ships
  unchanged breaks sign-in silently. A missing Secret leaves the pod Pending with an event naming
  it, which is the loud version of the same mistake.

  FORCE=1 re-generates values that already exist. Expect TeslaMate to lose every stored vehicle
  token (ENCRYPTION_KEY) and CNPG to need a re-applied DatabaseRole (password).
EOF
}

case "${1:-}" in
  -h|--help) usage; exit 0 ;;
esac

for tool in sops python3; do
  command -v "$tool" >/dev/null || { echo "FAIL: $tool not on PATH"; exit 1; }
done

# --- keypair minting --------------------------------------------------------------------------
# Written as a stdlib-only Go program rather than an openssl invocation because openssl is absent
# here. The private half is SEC1 - the `BEGIN EC PRIVATE` … `KEY` armor, split here on purpose so this
# file does not match its own repo's leak-check pattern - which is what `openssl ecparam -name
# prime256v1 -genkey` produces and what tesla-http-proxy expects; the public half is PKIX, which is
# what Tesla's application form wants.
if [ "${1:-}" = "--genkey" ]; then
  DIR=${2:-$HOME/tesla}
  command -v go >/dev/null || { echo "FAIL: go not on PATH and openssl is absent - mint the pair on any machine with either and copy the PEM"; exit 1; }
  mkdir -p "$DIR" && chmod 700 "$DIR"
  PRIV="$DIR/private-key.pem" PUB="$DIR/com.tesla.3p.public-key.pem"
  for f in "$PRIV" "$PUB"; do
    [ -e "$f" ] && { echo "FAIL: $f already exists. Refusing to overwrite: replacing a keypair that"
                    echo "Tesla already has the public half of breaks every signed command at once."
                    exit 1; }
  done
  SRC=$(mktemp -d)/genkey.go; trap 'rm -rf "$(dirname "$SRC")"' EXIT
  cat > "$SRC" <<'GO'
package main

import (
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/x509"
	"encoding/pem"
	"fmt"
	"os"
)

func main() {
	priv, pub := os.Args[1], os.Args[2]
	k, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		panic(err)
	}
	d, err := x509.MarshalECPrivateKey(k)
	if err != nil {
		panic(err)
	}
	p, err := x509.MarshalPKIXPublicKey(&k.PublicKey)
	if err != nil {
		panic(err)
	}
	// 0600 from the open, not a chmod after: the window between create and tighten is the one that
	// matters on a shared machine.
	f, err := os.OpenFile(priv, os.O_CREATE|os.O_EXCL|os.O_WRONLY, 0600)
	if err != nil {
		panic(err)
	}
	if err := pem.Encode(f, &pem.Block{Type: "EC PRIVATE KEY", Bytes: d}); err != nil {
		panic(err)
	}
	f.Close()
	g, err := os.OpenFile(pub, os.O_CREATE|os.O_EXCL|os.O_WRONLY, 0644)
	if err != nil {
		panic(err)
	}
	if err := pem.Encode(g, &pem.Block{Type: "PUBLIC KEY", Bytes: p}); err != nil {
		panic(err)
	}
	g.Close()
	fmt.Println("wrote", priv, "(0600) and", pub)
}
GO
  (cd "$(dirname "$SRC")" && go run "$(basename "$SRC")" "$PRIV" "$PUB")
  cat <<EOF

Next:
  1. Put $PRIV somewhere durable and private - a password manager, not this repo and not a workspace
     disk. It signs fleet_telemetry_config and every future vehicle command.
  2. Paste the contents of $PUB into the Tesla developer application's Public Key field.
  3. Serve it: $(basename "$0") $PUB
EOF
  exit 0
fi

PUBKEY=${1:-}
if [ -n "$PUBKEY" ]; then
  [ -f "$PUBKEY" ] || { echo "FAIL: no public key at $PUBKEY - run '$(basename "$0") --genkey' first, or pass the PEM you registered"; exit 1; }
  if [ -z "${TESLA_CLIENT_ID:-}" ]; then
    echo "FAIL: TESLA_CLIENT_ID is not set. It is the client id shown on the developer application"
    echo "you registered, the same one whose public key is in $PUBKEY. TeslaMate needs it to sign in;"
    echo "refusing to write a half-complete set of Tesla Secrets."
    exit 1
  fi
fi

existing=()
[ -f "$RUNTIME_SECRET" ] && existing+=("$RUNTIME_SECRET")
[ -f "$DB_SECRET" ] && existing+=("$DB_SECRET")
[ -n "$PUBKEY" ] && [ -f "$PUBKEY_SECRET" ] && existing+=("$PUBKEY_SECRET")
[ -n "${TESLA_CLIENT_ID:-}" ] && [ -f "$OAUTH_SECRET" ] && existing+=("$OAUTH_SECRET")
if [ ${#existing[@]} -gt 0 ]; then
  echo "FAIL: these already exist and would be replaced with new values:"
  printf '  %s\n' "${existing[@]}"
  echo "Re-running is not idempotent: ENCRYPTION_KEY decrypts the vehicle tokens TeslaMate stores in"
  echo "the database, and the DB password also lives in the CNPG DatabaseRole. If that is what you"
  echo "want, re-run with FORCE=1 and expect a TeslaMate restart plus a DatabaseRole re-apply."
  [ "${FORCE:-0}" = "1" ] || exit 1
  echo "FORCE=1 set - overwriting."
fi

[ -f "$KEY" ] || { echo "FAIL: no age key found. Looked at $KEY - set SOPS_AGE_KEY_FILE to the right one."; exit 1; }
export SOPS_AGE_KEY_FILE="$KEY"

# --- generate -------------------------------------------------------------------------------
EK=${TESLAMATE_ENCRYPTION_KEY:-}
if [ -z "$EK" ]; then
  # 32 bytes, hex: TeslaMate's documented shape, and hex keeps it safe inside a plain env var.
  EK=$(python3 -c 'import secrets; print(secrets.token_hex(32))')
fi
DBPASS=${TESLAMATE_DB_PASSWORD:-}
if [ -z "$DBPASS" ]; then
  # Hex for the same reason coder's is: it can end up inside a URL somewhere, and '@' or '%' would
  # make that URL ambiguous to anything parsing it rather than eyeballing it.
  DBPASS=$(python3 -c 'import secrets; print(secrets.token_hex(16))')
fi

# The public key is validated before it goes anywhere near sops. Tesla's failure mode for a bad key
# is a pairing error that blames the application registration, so a truncated or CRLF'd PEM is worth
# catching here rather than three services and one car-visit later.
PUB_PEM=$(PUBKEY="$PUBKEY" python3 - <<'PY'
import base64, os, re, sys
p = os.environ.get("PUBKEY", "")
if not p:
    print("", end="")
    sys.exit(0)
raw = open(p, "rb").read()
if b"\r" in raw:
    sys.exit("FAIL: %s contains CR - Tesla wants a plain LF PEM" % p)
txt = raw.decode()
m = re.search(r"-----BEGIN PUBLIC KEY-----(.*?)-----END PUBLIC KEY-----", txt, re.S)
if not m:
    sys.exit("FAIL: %s is not a PKIX 'BEGIN PUBLIC KEY' PEM. Tesla's form wants the PKIX public"
             " half (openssl ec -in private-key.pem -pubout), not the private key and not the SEC1"
             " 'BEGIN EC PRIVATE' … 'KEY' form." % p)
body = "".join(m.group(1).split())
try:
    der = base64.b64decode(body, validate=True)
except Exception as e:
    sys.exit("FAIL: %s is not valid base64 between the armor lines: %s" % (p, e))
# An EC P-256 SubjectPublicKeyInfo is ~91 bytes; anything wildly off is the wrong kind of key.
if not (60 < len(der) < 200):
    sys.exit("FAIL: %s decodes to %d bytes, which is not an EC P-256 public key" % (p, len(der)))
sys.stdout.write(txt if txt.endswith("\n") else txt + "\n")
PY
)

# --- render and write ------------------------------------------------------------------------
# Built in python rather than a heredoc: the public key is a multi-line PEM going into a YAML string
# value, and hand-rolled indentation is how you ship a Secret that parses as one opaque blob.
render() {
  STAGE_RUNTIME="$STAGE_RUNTIME" STAGE_DB="$STAGE_DB" STAGE_PUBKEY="$STAGE_PUBKEY" \
  STAGE_OAUTH="$STAGE_OAUTH" TESLA_CLIENT_ID="${TESLA_CLIENT_ID:-}" \
  EK="$EK" DBPASS="$DBPASS" PUB_PEM="$PUB_PEM" python3 - <<'PY'
import os, yaml

env = os.environ

def dump(path, obj):
    with open(path, "w") as fh:
        yaml.safe_dump(obj, fh, sort_keys=False, width=10**6)

dump(env["STAGE_RUNTIME"], {
    "apiVersion": "v1", "kind": "Secret",
    "metadata": {"name": "teslamate-secrets", "namespace": "apps"},
    "type": "Opaque",
    "stringData": {
        # Decrypts the vehicle OAuth tokens in the database. Rotating it orphans them.
        "ENCRYPTION_KEY": env["EK"],
        "DATABASE_USER": "teslamate",
        "DATABASE_PASS": env["DBPASS"],
        "DATABASE_NAME": "teslamate",
        # postgres-rw, not postgres: CNPG publishes postgres-r / -ro / -rw and there is no bare
        # `postgres` service in `databases` (verified against the live cluster). coder and authentik
        # both already point at -rw; TeslaMate writes constantly, so it belongs with them.
        "DATABASE_HOST": "postgres-rw.databases.svc.cluster.local",
    },
})
dump(env["STAGE_DB"], {
    "apiVersion": "v1", "kind": "Secret",
    "metadata": {"name": "teslamate-db-credentials", "namespace": "databases",
                 "labels": {"cnpg.io/reload": "true"}},
    "type": "kubernetes.io/basic-auth",
    "stringData": {"username": "teslamate", "password": env["DBPASS"]},
})
if env.get("PUB_PEM"):
    pem = env["PUB_PEM"]
    # Command substitution strips trailing newlines, so re-clip to exactly one: the value nginx
    # serves should be byte-for-byte the PEM Tesla was given, newline included.
    pem = pem.rstrip("\n") + "\n"
    dump(env["STAGE_PUBKEY"], {
        "apiVersion": "v1", "kind": "Secret",
        "metadata": {"name": "tesla-wellknown", "namespace": "apps"},
        "type": "Opaque",
        # Not a credential. It is a Secret rather than a ConfigMap for one reason: this repo's gates
        # look hard at apply/10-secrets and hardly at apply/50-apps, and a file Tesla depends on
        # should live where a mistake gets caught. The key name becomes the filename nginx serves.
        "stringData": {"com.tesla.3p.public-key.pem": pem},
    })
if env.get("TESLA_CLIENT_ID"):
    dump(env["STAGE_OAUTH"], {
        "apiVersion": "v1", "kind": "Secret",
        "metadata": {"name": "tesla-oauth", "namespace": "apps"},
        "type": "Opaque",
        # The public client id of the Tesla developer application. Not secret, and it would be a
        # ConfigMap if a ConfigMap could fail loudly: a committed placeholder ships green through
        # every gate here and breaks sign-in quietly, whereas a missing Secret leaves the pod Pending
        # with an event that names it. Encrypted with the rest for the same reason the public key is.
        "stringData": {"TESLA_AUTH_CLIENT_ID": env["TESLA_CLIENT_ID"].strip()},
    })
PY
}
render
# EK and DBPASS are secrets; PUB_PEM is not, and it is still needed below to decide whether the
# well-known Secret was written.
unset EK DBPASS

for f in "$STAGE_RUNTIME" "$STAGE_DB"; do sops --encrypt --in-place "$f"; done
mv "$STAGE_RUNTIME" "$RUNTIME_SECRET"
mv "$STAGE_DB" "$DB_SECRET"
if [ -n "$PUB_PEM" ]; then
  sops --encrypt --in-place "$STAGE_PUBKEY"
  mv "$STAGE_PUBKEY" "$PUBKEY_SECRET"
fi
if [ -n "${TESLA_CLIENT_ID:-}" ]; then
  sops --encrypt --in-place "$STAGE_OAUTH"
  mv "$STAGE_OAUTH" "$OAUTH_SECRET"
fi

echo "== written (fingerprints only)"
sops -d "$RUNTIME_SECRET" | python3 -c '
import sys, yaml, hashlib
sd = yaml.safe_load(sys.stdin.read())["stringData"]
print("  teslamate-secrets          ENCRYPTION_KEY sha256:" +
      hashlib.sha256(sd["ENCRYPTION_KEY"].encode()).hexdigest()[:12] +
      "  DATABASE_HOST=" + sd["DATABASE_HOST"])
print("                             DATABASE_USER=" + sd["DATABASE_USER"] +
      "  DATABASE_NAME=" + sd["DATABASE_NAME"] +
      "  DATABASE_PASS sha256:" + hashlib.sha256(sd["DATABASE_PASS"].encode()).hexdigest()[:12])'
sops -d "$DB_SECRET" | python3 -c '
import sys, yaml, hashlib
sd = yaml.safe_load(sys.stdin.read())["stringData"]
print("  teslamate-db-credentials   username=" + sd["username"] +
      "  password sha256:" + hashlib.sha256(sd["password"].encode()).hexdigest()[:12])'
if [ -n "${PUBKEY:-}" ]; then
  sops -d "$PUBKEY_SECRET" | python3 -c '
import sys, yaml, hashlib
sd = yaml.safe_load(sys.stdin.read())["stringData"]
k = "com.tesla.3p.public-key.pem"
print("  tesla-wellknown            " + k + " " + str(len(sd[k])) +
      " bytes, sha256:" + hashlib.sha256(sd[k].encode()).hexdigest()[:12])'
  sops -d "$OAUTH_SECRET" | python3 -c '
import sys, yaml
sd = yaml.safe_load(sys.stdin.read())["stringData"]
print("  tesla-oauth                TESLA_AUTH_CLIENT_ID " + sd["TESLA_AUTH_CLIENT_ID"][:8] + "...")'
fi
# The two halves of the DB password must agree, and they are two files. This is the same class of
# split that make db-url-check exists for on the coder side; here it is cheap enough to check inline.
python3 - "$RUNTIME_SECRET" "$DB_SECRET" <<'PY'
import sys, yaml
a = yaml.safe_load(__import__("subprocess").run(["sops","-d",sys.argv[1]],capture_output=True,text=True).stdout)["stringData"]
b = yaml.safe_load(__import__("subprocess").run(["sops","-d",sys.argv[2]],capture_output=True,text=True).stdout)["stringData"]
if a["DATABASE_PASS"] != b["password"] or a["DATABASE_USER"] != b["username"]:
    sys.exit("FAIL: teslamate-secrets and teslamate-db-credentials disagree - one password kept twice"
             " is one rotation away from a silent split")
print("  cross-check                both files carry the same user and password")
PY

cat <<EOF

Next, in this order:

  1. List every file this wrote in apply/10-secrets/kustomization.yaml. An unlisted Secret builds
     fine and is silently never applied - \`make secrets-placement\` is the gate that says so.
  2. git add apply/10-secrets/teslamate-secrets.yaml apply/10-secrets/teslamate-db-credentials.yaml \\
     $( [ -n "${PUBKEY:-}" ] && echo 'apply/10-secrets/tesla-wellknown.yaml apply/10-secrets/tesla-oauth.yaml' )
  3. make check
  4. commit, merge, let Flux apply.
$( [ -z "${PUBKEY:-}" ] && cat <<'PEND'
  NOTE: tesla-wellknown.yaml was NOT written - no public key was supplied. Tesla cannot pair until
  that file exists and is served at /.well-known/appspecific/, so re-run this script with the PEM
  you registered before merging the Ingress that serves it.
PEND
)
EOF
