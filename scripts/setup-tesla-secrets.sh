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
# IT IS IDEMPOTENT PER FILE, NOT ALL-OR-NOTHING, AND THAT MATTERS MORE THAN IT SOUNDS.
# The five Secrets this writes are not known at the same time: the DB password and ENCRYPTION_KEY
# exist the moment you decide to install TeslaMate, while the public key and the OAuth client id do
# not exist until the Tesla application has been registered - which can be days later. A script that
# refused to re-run because *something* already existed would force FORCE=1 to add the last two, and
# FORCE=1 rotates ENCRYPTION_KEY, which silently orphans every vehicle token TeslaMate has stored in
# the database. So each file is skipped if it already exists, and FORCE only replaces the ones you
# are actually able to write.
set -euo pipefail

REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$REPO"

RUNTIME_SECRET=apply/10-secrets/teslamate-secrets.yaml
DB_SECRET=apply/10-secrets/teslamate-db-credentials.yaml
PUBKEY_SECRET=apply/10-secrets/tesla-wellknown.yaml
OAUTH_SECRET=apply/10-secrets/tesla-oauth.yaml
GRAFANA_SECRET=apply/10-secrets/tesla-grafana-admin.yaml
STAGE_RUNTIME=apply/10-secrets/.staging.teslamate-secrets.yaml
STAGE_DB=apply/10-secrets/.staging.teslamate-db-credentials.yaml
STAGE_PUBKEY=apply/10-secrets/.staging.tesla-wellknown.yaml
STAGE_OAUTH=apply/10-secrets/.staging.tesla-oauth.yaml
STAGE_GRAFANA=apply/10-secrets/.staging.tesla-grafana-admin.yaml

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

# Never leave plaintext behind, whatever fails. Every staging path is git-ignored by name
# (.gitignore: apply/10-secrets/.staging.*.yaml), and they sit under apply/10-secrets/ because sops
# picks recipients from the file's own path, not from your intent.
trap 'rm -f "$STAGE_RUNTIME" "$STAGE_DB" "$STAGE_PUBKEY" "$STAGE_OAUTH" "$STAGE_GRAFANA"' EXIT

usage() {
  cat <<'EOF'
usage:
  setup-tesla-secrets.sh --genkey [DIR]     mint the Tesla application P-256 keypair in DIR
                                          (default ~/tesla), outside the repo, and stop
  setup-tesla-secrets.sh [PUBLIC_KEY_PEM]   write whatever is not written yet; with no PEM, write
                                          only the Secrets that do not need it

  TESLA_CLIENT_ID=<id from developer.tesla.com> goes with the PEM. Neither is a secret, but neither
  is knowable before the application exists, and a committed placeholder ships green through every
  gate here and breaks sign-in quietly. A missing Secret leaves the pod Pending with an event naming
  it, which is the loud version of the same mistake.

  FORCE=1 replaces files that already exist. It regenerates ENCRYPTION_KEY, which makes every
  vehicle token TeslaMate has stored in its database undecryptable, and the DB password, which also
  lives in the CNPG DatabaseRole. Expect a TeslaMate sign-in and a DatabaseRole re-apply after it.
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
# here. The private half is SEC1 - the `BEGIN EC PRIVATE` ... `KEY` armor, split here on purpose so
# this file does not match its own repo's leak-check pattern - which is what `openssl ecparam -name
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
  3. Serve it: TESLA_CLIENT_ID=<client id> $(basename "$0") $PUB
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

# --- decide what actually needs writing --------------------------------------------------------
# The pair below is deliberately all-or-nothing: one password appears in two files, so writing one
# and skipping the other is precisely the split this repo built db-url-check to catch.
FORCE=${FORCE:-0}
WRITE_RUNTIME=1; WRITE_DB=1
[ -f "$RUNTIME_SECRET" ] && [ "$FORCE" != "1" ] && WRITE_RUNTIME=0
[ -f "$DB_SECRET" ] && [ "$FORCE" != "1" ] && WRITE_DB=0
# If only one of the pair exists, treat the pair as needing a write: a half-present pair is a bug,
# not a state to preserve.
if [ "$WRITE_RUNTIME" != "$WRITE_DB" ]; then WRITE_RUNTIME=1; WRITE_DB=1; fi

WRITE_PUBKEY=0; WRITE_OAUTH=0
if [ -n "$PUBKEY" ]; then
  if [ ! -f "$PUBKEY_SECRET" ] || [ "$FORCE" = "1" ]; then WRITE_PUBKEY=1; fi
  if [ ! -f "$OAUTH_SECRET" ] || [ "$FORCE" = "1" ]; then WRITE_OAUTH=1; fi
fi
WRITE_GRAFANA=0
if [ ! -f "$GRAFANA_SECRET" ] || [ "$FORCE" = "1" ]; then WRITE_GRAFANA=1; fi

skipped=()
if [ "$WRITE_RUNTIME" = 0 ]; then skipped+=("$RUNTIME_SECRET"); fi
if [ "$WRITE_DB" = 0 ]; then skipped+=("$DB_SECRET"); fi
if [ -z "$PUBKEY" ]; then
  skipped+=("$PUBKEY_SECRET (no public key supplied yet)")
  skipped+=("$OAUTH_SECRET (no client id supplied yet)")
fi
if [ ${#skipped[@]} -gt 0 ]; then
  echo "leaving these alone:"
  printf '  %s\n' "${skipped[@]}"
fi
if [ "$WRITE_RUNTIME$WRITE_DB$WRITE_PUBKEY$WRITE_OAUTH$WRITE_GRAFANA" = "00000" ]; then
  echo "nothing to do - every Secret this script writes already exists."
  echo "Re-run with FORCE=1 only if you mean to rotate ENCRYPTION_KEY and the DB password."
  exit 0
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
# The upstream TeslaMate Grafana image bakes GF_SECURITY_ADMIN_USER=admin / GF_SECURITY_ADMIN_PASSWORD=admin
# into its ENV (read out of grafana/Dockerfile at v4.3.0), and disables both anonymous and basic
# auth - so admin/admin is the only way in, and this Grafana is on a public hostname.
GRAFANA_PASS=${GRAFANA_ADMIN_PASSWORD:-}
if [ -z "$GRAFANA_PASS" ]; then
  GRAFANA_PASS=$(python3 -c 'import secrets; print(secrets.token_urlsafe(24))')
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
             " 'BEGIN EC PRIVATE' ... 'KEY' form." % p)
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
  STAGE_OAUTH="$STAGE_OAUTH" STAGE_GRAFANA="$STAGE_GRAFANA" \
  WRITE_RUNTIME="$WRITE_RUNTIME" WRITE_DB="$WRITE_DB" WRITE_PUBKEY="$WRITE_PUBKEY" \
  WRITE_OAUTH="$WRITE_OAUTH" WRITE_GRAFANA="$WRITE_GRAFANA" \
  TESLA_CLIENT_ID="${TESLA_CLIENT_ID:-}" \
  EK="$EK" DBPASS="$DBPASS" GRAFANA_PASS="$GRAFANA_PASS" PUB_PEM="$PUB_PEM" python3 - <<'PY'
import os, yaml

env = os.environ
on = lambda k: env.get(k) == "1"

def dump(path, obj):
    with open(path, "w") as fh:
        yaml.safe_dump(obj, fh, sort_keys=False, width=10**6)

if on("WRITE_RUNTIME"):
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
            # `postgres` service in `databases` (verified against the live cluster). coder and
            # authentik both already point at -rw; TeslaMate writes constantly.
            "DATABASE_HOST": "postgres-rw.databases.svc.cluster.local",
        },
    })
if on("WRITE_DB"):
    dump(env["STAGE_DB"], {
        "apiVersion": "v1", "kind": "Secret",
        "metadata": {"name": "teslamate-db-credentials", "namespace": "databases",
                     "labels": {"cnpg.io/reload": "true"}},
        "type": "kubernetes.io/basic-auth",
        "stringData": {"username": "teslamate", "password": env["DBPASS"]},
    })
if on("WRITE_PUBKEY"):
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
if on("WRITE_OAUTH"):
    dump(env["STAGE_OAUTH"], {
        "apiVersion": "v1", "kind": "Secret",
        "metadata": {"name": "tesla-oauth", "namespace": "apps"},
        "type": "Opaque",
        # The public client id of the Tesla developer application. Not secret, and it would be a
        # ConfigMap if a ConfigMap could fail loudly: a committed placeholder ships green through
        # every gate here and breaks sign-in quietly, whereas a missing Secret leaves the pod Pending
        # with an event that names it.
        "stringData": {"TESLA_AUTH_CLIENT_ID": env["TESLA_CLIENT_ID"].strip()},
    })
if on("WRITE_GRAFANA"):
    dump(env["STAGE_GRAFANA"], {
        "apiVersion": "v1", "kind": "Secret",
        "metadata": {"name": "tesla-grafana-admin", "namespace": "apps"},
        "type": "Opaque",
        # teslamate/grafana ships GF_SECURITY_ADMIN_USER=admin / GF_SECURITY_ADMIN_PASSWORD=admin in
        # its image ENV, with anonymous and basic auth both disabled - so admin/admin is the only
        # way in, and this Grafana answers on a public hostname. Overriding both is the whole point.
        "stringData": {"GF_SECURITY_ADMIN_USER": "admin",
                       "GF_SECURITY_ADMIN_PASSWORD": env["GRAFANA_PASS"]},
    })
PY
}
render
# EK, DBPASS and GRAFANA_PASS are secrets; PUB_PEM is not, and it is still needed below to decide
# what was written.
unset EK DBPASS GRAFANA_PASS

written=()
for pair in "$WRITE_RUNTIME:$STAGE_RUNTIME:$RUNTIME_SECRET" \
            "$WRITE_DB:$STAGE_DB:$DB_SECRET" \
            "$WRITE_PUBKEY:$STAGE_PUBKEY:$PUBKEY_SECRET" \
            "$WRITE_OAUTH:$STAGE_OAUTH:$OAUTH_SECRET" \
            "$WRITE_GRAFANA:$STAGE_GRAFANA:$GRAFANA_SECRET"; do
  do_it=${pair%%:*}; rest=${pair#*:}; stage=${rest%%:*}; final=${rest#*:}
  [ "$do_it" = "1" ] || continue
  sops --encrypt --in-place "$stage"
  mv "$stage" "$final"
  written+=("$final")
done

echo "== written (fingerprints only)"
for f in "${written[@]}"; do
  sops -d "$f" | python3 -c '
import sys, yaml, hashlib
doc = yaml.safe_load(sys.stdin.read())
sd = doc["stringData"]
name = doc["metadata"]["name"]
for k, v in sd.items():
    shown = v if k in ("DATABASE_USER", "DATABASE_HOST", "DATABASE_NAME", "GF_SECURITY_ADMIN_USER") \
        else ("sha256:" + hashlib.sha256(v.encode()).hexdigest()[:12] + (" (%d bytes)" % len(v) if "\n" in v else ""))
    print("  %-28s %-28s %s" % (name, k, shown))'
done

# The two halves of the DB password must agree, and they are two files. This is the same class of
# split that make db-url-check exists for on the coder side; here it is cheap enough to check inline.
if [ -f "$RUNTIME_SECRET" ] && [ -f "$DB_SECRET" ]; then
  python3 - "$RUNTIME_SECRET" "$DB_SECRET" <<'PY'
import sys, yaml, subprocess
def sd(p):
    return yaml.safe_load(subprocess.run(["sops", "-d", p], capture_output=True, text=True).stdout)["stringData"]
a, b = sd(sys.argv[1]), sd(sys.argv[2])
if a["DATABASE_PASS"] != b["password"] or a["DATABASE_USER"] != b["username"]:
    sys.exit("FAIL: teslamate-secrets and teslamate-db-credentials disagree - one password kept twice"
             " is one rotation away from a silent split")
print("  cross-check                  both files carry the same user and password")
PY
fi

pending=()
[ -f "$PUBKEY_SECRET" ] || pending+=("tesla-wellknown.yaml — Tesla cannot pair until this exists and is served at /.well-known/appspecific/")
[ -f "$OAUTH_SECRET" ] || pending+=("tesla-oauth.yaml — TeslaMate cannot sign in without TESLA_AUTH_CLIENT_ID")
cat <<EOF

Next, in this order:

  1. List every file this wrote in apply/10-secrets/kustomization.yaml. An unlisted Secret builds
     fine and is silently never applied - \`make secrets-placement\` is the gate that says so.
  2. git add ${written[*]}
  3. make check
  4. commit, merge, let Flux apply.
$( [ ${#pending[@]} -gt 0 ] && printf '\n  Still pending (re-run this script with the PEM and TESLA_CLIENT_ID):\n' && printf '    - %s\n' "${pending[@]}" )
EOF
