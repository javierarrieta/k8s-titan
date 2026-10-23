#!/usr/bin/env bash
# Mint everything OpenCloud and Collabora need and write it, sops-encrypted, to apply/10-secrets.
#
# RUN IT, DON'T READ IT INTO A SHELL. The operator's login shell is fish, which has no heredocs and
# no `read -rs -p`; this file's bash-isms are deliberate and the shebang is the interpreter.
#
# WHY THE MINIO CREDENTIALS ARE PROMPTED AND THE REST IS GENERATED
# The S3 pair is not ours to mint: the bucket, the service account and the policy are created on
# casa's MinIO with `mc` (docs/opencloud-minio.md), so this script has to be told what was created
# there. If apply/10-secrets/opencloud-secrets.yaml already exists and decrypts, the pair is reused
# from it rather than asked for again - that is the common case, because the credential is staged
# before the app is. Everything else is internal to titan and is generated here so it is long,
# random and never typed.
#
# WHAT CHANGED FROM THE oCIS SCRIPT THIS ONE WAS PORTED FROM
#   dropped   admin-user, admin-password - OCIS_ADMIN_USER and OCIS_ADMIN_PASSWORD have no
#             replacement in OpenCloud 8.1.0, and there is no user/role CLI. docs/opencloud-admin.md.
#   dropped   idm-admin-password - idm only gates on the three service-user passwords
#             (services/idm/pkg/config/parser/parse.go:41-55), and the local admin account it was for
#             is not created when OC_ADMIN_USER_ID is unset.
#   added     url-signing-secret - OC_URL_SIGNING_SECRET, new in 4.0.0 and gated by the proxy
#             (services/proxy/pkg/config/parser/parse.go:78).
#   kept      idm-admin-password - dropped in the first port on the reasoning that nothing needed it.
#             Wrong: it becomes mandatory the moment OC_ADMIN_USER_ID is set, which is the admin
#             grant. See docs/opencloud-admin.md.
#   added     the identifier block printed at the end, which is not Secret material and belongs in git.
#
# THE PROOF KEY IS A SECRET, NOT A RUNTIME ARTIFACT
# collabora/code 26.x has no shell and no coolconfig, so nothing in the image can mint the WOPI proof
# key at startup. Minting it here and storing it in git (encrypted) is what makes it survive a pod
# recreate. If it changes, OpenCloud is left holding a stale public key and document opening fails
# with a proof-key validation error that has nothing to do with where it came from. Rotate deliberately.
#
# WHY THE TOOLCHAIN HAS A FALLBACK
# The oCIS script this was ported from required openssl. This workspace has no openssl on PATH and no
# python cryptography, and the WOPI proof key still has to come from somewhere, so the minting helpers
# prefer openssl and fall back to ssh-keygen (which emits a PKCS#1 PEM with -m PEM, which is what
# coolwsd expects) and python3's secrets module. Same output shape either way; the fallback exists so
# the script runs where the operator actually runs it rather than only where it was written.
#
# Nothing prints a value. What you see is a truncated SHA-256 per file.
set -euo pipefail

REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$REPO"

rand_hex() { # $1 = number of bytes
  if command -v openssl >/dev/null; then openssl rand -hex "$1"
  else python3 -c "import secrets,sys;print(secrets.token_hex(int(sys.argv[1])))" "$1"
  fi
}
rand_b64() { # $1 = number of bytes
  if command -v openssl >/dev/null; then openssl rand -base64 "$1"
  else python3 -c "import secrets,base64,sys;print(base64.b64encode(secrets.token_bytes(int(sys.argv[1]))).decode())" "$1"
  fi
}
uuid4() { cat /proc/sys/kernel/random/uuid 2>/dev/null || python3 -c "import uuid;print(uuid.uuid4())"; }
rsa_pem() {
  if command -v openssl >/dev/null; then openssl genrsa 2048 2>/dev/null; return; fi
  local tmp; tmp=$(mktemp -d); trap 'rm -rf "$tmp"' RETURN
  ssh-keygen -q -t rsa -b 2048 -m PEM -N "" -f "$tmp/k" -C "" 2>/dev/null
  cat "$tmp/k"
}

TARGET=apply/10-secrets/opencloud-secrets.yaml
STAGE=apply/10-secrets/.staging.opencloud-secrets.yaml
KEY=${SOPS_AGE_KEY_FILE:-$HOME/.config/sops/age/keys.txt}

# Never leave plaintext behind, whatever fails. The staging path is git-ignored by name
# (apply/10-secrets/.staging.*.yaml) and sits under apply/10-secrets/ because sops picks its
# recipients from the file's own path, not from your intent.
trap 'rm -f "$STAGE"' EXIT

for tool in sops; do
  command -v "$tool" >/dev/null || { echo "FAIL: $tool not on PATH"; exit 1; }
done
if ! command -v openssl >/dev/null && ! command -v ssh-keygen >/dev/null; then
  echo "FAIL: need openssl, or ssh-keygen as a fallback for the WOPI proof key"; exit 1
fi
[ -f "$KEY" ] || { echo "FAIL: no age key at $KEY - set SOPS_AGE_KEY_FILE to the file holding the titan-k8s private key"; exit 1; }
export SOPS_AGE_KEY_FILE="$KEY"

# Reuse the S3 pair from an existing encrypted Secret when there is one. Reading it back through sops
# rather than asking again is the difference between a re-run and a rotation: a re-run must not
# silently mint a key that MinIO has never heard of.
S3_ACCESS_KEY=""; S3_SECRET_KEY=""
if [ -f "$TARGET" ] && S3_ACCESS_KEY=$(sops -d "$TARGET" 2>/dev/null | sed -n 's/^[[:space:]]*s3-access-key:[[:space:]]*//p') && [ -n "$S3_ACCESS_KEY" ]; then
  S3_SECRET_KEY=$(sops -d "$TARGET" | sed -n 's/^[[:space:]]*s3-secret-key:[[:space:]]*//p')
  echo "reusing the existing S3 pair from $TARGET"
else
  S3_ACCESS_KEY=""; S3_SECRET_KEY=""
  echo "MinIO credentials for the opencloud service account on casa (created with mc, not here)."
  printf 'S3 access key: '
  read -r S3_ACCESS_KEY
  printf 'S3 secret key (input hidden): '
  read -rs S3_SECRET_KEY
  echo
fi

JWT_SECRET=$(rand_hex 32)
MACHINE_AUTH_API_KEY=$(uuid4)
TRANSFER_SECRET=$(rand_hex 32)
URL_SIGNING_SECRET=$(rand_hex 32)
WOPI_SECRET=$(rand_hex 32)
SYSTEM_USER_API_KEY=$(uuid4)
# The idm LDAP layer, which auth-basic, users, groups, graph and idp bind against. LDAP_BIND_PASSWORD
# is deliberately the same value as IDM_REVA_PASSWORD: the default bind DN is
# uid=reva,ou=sysusers,o=libregraph-idm, so idm provisions that user from one and the others
# authenticate with the other. Getting this wrong is an LDAP 49 at first login, not a startup failure.
IDM_SVC_PASSWORD=$(rand_hex 24)
IDM_REVA_PASSWORD=$(rand_hex 24)
IDP_SVC_PASSWORD=$(rand_hex 24)
# Minted even though it is unused until OC_ADMIN_USER_ID is filled in: idm requires it the moment that
# value is non-empty (services/idm/pkg/config/parser/parse.go:45), and having to re-run this script -
# which mints every OTHER value again - in order to become an administrator would be a bad trade.
IDM_ADMIN_PASSWORD=$(rand_hex 24)
LDAP_BIND_PASSWORD="$IDM_REVA_PASSWORD"
SERVICE_ACCOUNT_SECRET=$(rand_hex 24)
THUMBNAILS_TRANSFER_TOKEN=$(rand_hex 32)
COLLABORA_ADMIN_USER=admin
COLLABORA_ADMIN_PASSWORD=$(rand_b64 24)
PROOF_KEY=$(rsa_pem)

# Stable identifiers. NOT credentials - they must be non-empty and must never change once data exists,
# so they belong in git where a rotation is a diff. The mount ID in particular orphans the storage
# tree if it changes after files exist.
#
# Read back from the manifest when it already carries real ones. Without this, re-running the script to
# add or rotate one Secret value would mint four new identifiers, print them, and leave the manifest
# holding the old ones - a silent divergence of exactly the kind these are in git to make visible. The
# manifest is the source of truth here, not this script.
MANIFEST=apply/50-apps/opencloud/opencloud.yaml
read_ident() {
  awk -v n="$1" '
    $0 ~ ("- name: " n "$") { f = 1; next }
    f && /value:/ { gsub(/^ *value: *|"/, ""); print; exit }
  ' "$MANIFEST"
}

SYSTEM_USER_ID=$(read_ident OC_SYSTEM_USER_ID)
MOUNT_ID=$(read_ident STORAGE_USERS_MOUNT_ID)
SERVICE_ACCOUNT_ID=$(read_ident OC_SERVICE_ACCOUNT_ID)
GRAPH_APPLICATION_ID=$(read_ident GRAPH_APPLICATION_ID)

if [ -n "$SYSTEM_USER_ID" ] && [ "$SYSTEM_USER_ID" != "PLACEHOLDER_SYSTEM_USER_ID" ]; then
  echo "reusing the identifiers already in $MANIFEST"
else
  SYSTEM_USER_ID=$(uuid4)
  MOUNT_ID=$(uuid4)
  SERVICE_ACCOUNT_ID=$(uuid4)
  GRAPH_APPLICATION_ID=$(uuid4)
fi

[ -n "$S3_ACCESS_KEY" ] || { echo "FAIL: empty S3 access key"; exit 1; }
[ -n "$S3_SECRET_KEY" ] || { echo "FAIL: empty S3 secret key"; exit 1; }
[ -n "$PROOF_KEY" ] || { echo "FAIL: openssl produced no proof key"; exit 1; }

cat > "$STAGE" <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: opencloud-secrets
  namespace: files
type: Opaque
# stringData, not data - and that is a repo convention with a gate behind it, not a style preference.
# Every other Secret in apply/10-secrets uses stringData. `make dry-run` strips the sops envelope and
# submits the ciphertext as-is to mimic what kustomize-controller sends, and the API server
# base64-decodes `data` but never `stringData`. Values are plaintext here because sops encrypts this
# whole document on the next line.
stringData:
  jwt-secret: "$JWT_SECRET"
  machine-auth-api-key: "$MACHINE_AUTH_API_KEY"
  transfer-secret: "$TRANSFER_SECRET"
  url-signing-secret: "$URL_SIGNING_SECRET"
  system-user-api-key: "$SYSTEM_USER_API_KEY"
  ldap-bind-password: "$LDAP_BIND_PASSWORD"
  idm-svc-password: "$IDM_SVC_PASSWORD"
  idm-reva-password: "$IDM_REVA_PASSWORD"
  idp-svc-password: "$IDP_SVC_PASSWORD"
  idm-admin-password: "$IDM_ADMIN_PASSWORD"
  service-account-secret: "$SERVICE_ACCOUNT_SECRET"
  thumbnails-transfer-token: "$THUMBNAILS_TRANSFER_TOKEN"
  wopi-secret: "$WOPI_SECRET"
  s3-access-key: "$S3_ACCESS_KEY"
  s3-secret-key: "$S3_SECRET_KEY"
  collabora-admin-user: "$COLLABORA_ADMIN_USER"
  collabora-admin-password: "$COLLABORA_ADMIN_PASSWORD"
  collabora-proof-key: |
$(printf '%s\n' "$PROOF_KEY" | sed 's/^/    /')
EOF

sops --encrypt --in-place "$STAGE"
mv "$STAGE" "$TARGET"
trap - EXIT

echo "wrote $TARGET"
echo "sha256 ${TARGET}: $(sha256sum "$TARGET" | cut -c1-16)"
echo
echo "Identifiers (not secrets). If these differ from apply/50-apps/opencloud/opencloud.yaml, paste"
echo "them over the values there - the two mount-ID lines take the SAME value:"
echo
echo "  OC_SYSTEM_USER_ID:             $SYSTEM_USER_ID"
echo "  STORAGE_USERS_MOUNT_ID:        $MOUNT_ID"
echo "  GATEWAY_STORAGE_USERS_MOUNT_ID:$MOUNT_ID"
echo "  OC_SERVICE_ACCOUNT_ID:         $SERVICE_ACCOUNT_ID"
echo "  GRAPH_APPLICATION_ID:          $GRAPH_APPLICATION_ID"
echo
echo "Next: sops -d $TARGET | head -3 should print the plaintext Secret."
echo "Then: git add $TARGET apply/50-apps/opencloud/opencloud.yaml and make check."
