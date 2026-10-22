#!/usr/bin/env bash
# Mint everything oCIS and Collabora need and write it, sops-encrypted, to apply/10-secrets.
#
# RUN IT, DON'T READ IT INTO A SHELL. The operator's login shell is fish, which has no heredocs and
# no `read -rs -p`; this file's bash-isms are deliberate and the shebang is the interpreter.
#
# WHY THE MINIO CREDENTIALS ARE PROMPTED AND THE REST IS GENERATED
# The S3 pair is not ours to mint: the bucket, the IAM user and the bucket policy are created on
# casa's MinIO with `mc` (see scratch/ocis-bucket-policy.json), so this script has to be told what
# was created there. Everything else is internal to titan and is generated here so it is long,
# random and never typed.
#
# THE PROOF KEY IS A SECRET, NOT A RUNTIME ARTIFACT
# collabora/code 26.x has no shell and no coolconfig, so nothing in the image can mint the WOPI proof
# key at startup. Minting it here and storing it in git (encrypted) is what makes it survive a pod
# recreate. If it changes, oCIS is left holding a stale public key and document opening fails with
# a proof-key validation error that has nothing to do with where it came from. Rotate deliberately.
#
# Nothing prints a value. What you see is a truncated SHA-256 per file.
set -euo pipefail

REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$REPO"

TARGET=apply/10-secrets/ocis-secrets.yaml
STAGE=apply/10-secrets/.staging.ocis-secrets.yaml
KEY=${SOPS_AGE_KEY_FILE:-$HOME/.config/sops/age/keys.txt}

# Never leave plaintext behind, whatever fails. The staging path is git-ignored by name
# (apply/10-secrets/.staging.*.yaml) and sits under apply/10-secrets/ because sops picks its
# recipients from the file's own path, not from your intent.
trap 'rm -f "$STAGE"' EXIT

for tool in sops openssl; do
  command -v "$tool" >/dev/null || { echo "FAIL: $tool not on PATH"; exit 1; }
done
[ -f "$KEY" ] || { echo "FAIL: no age key at $KEY - set SOPS_AGE_KEY_FILE to the file holding the titan-k8s private key"; exit 1; }
export SOPS_AGE_KEY_FILE="$KEY"
[ -f "$TARGET" ] && { echo "FAIL: $TARGET already exists - edit it with sops rather than overwriting"; exit 1; }

echo "MinIO credentials for the oCIS user on casa (created with mc, not by this script)."
printf 'S3 access key: '
read -r S3_ACCESS_KEY
printf 'S3 secret key (input hidden): '
read -rs S3_SECRET_KEY
echo

ADMIN_USER=admin
COLLABORA_ADMIN_USER=admin
ADMIN_PASSWORD=$(openssl rand -base64 24)
JWT_SECRET=$(openssl rand -hex 32)
MACHINE_AUTH_API_KEY=$(cat /proc/sys/kernel/random/uuid)
COLLABORA_ADMIN_PASSWORD=$(openssl rand -base64 24)
# Three more that oCIS validates at startup and will not boot without - see the env blocks in
# apply/50-apps/ocis/ocis.yaml for which service checks which.
TRANSFER_SECRET=$(openssl rand -hex 32)
WOPI_SECRET=$(openssl rand -hex 32)
SYSTEM_USER_API_KEY=$(cat /proc/sys/kernel/random/uuid)
# The embedded idm LDAP layer, which auth-basic, users, groups, graph and idp bind against.
# LDAP_BIND_PASSWORD is deliberately the same value as IDM_REVA_PASSWORD: the default bind DN is
# uid=reva,ou=sysusers,o=libregraph-idm, so idm provisions that user from one and the others
# authenticate with the other. See the env block in apply/50-apps/ocis/ocis.yaml.
IDM_SVC_PASSWORD=$(openssl rand -hex 24)
IDM_REVA_PASSWORD=$(openssl rand -hex 24)
IDP_SVC_PASSWORD=$(openssl rand -hex 24)
IDM_ADMIN_PASSWORD=$(openssl rand -hex 24)
LDAP_BIND_PASSWORD="$IDM_REVA_PASSWORD"
SERVICE_ACCOUNT_SECRET=$(openssl rand -hex 24)
THUMBNAILS_TRANSFER_TOKEN=$(openssl rand -hex 32)
PROOF_KEY=$(openssl genrsa 2048 2>/dev/null)

[ -n "$S3_ACCESS_KEY" ] || { echo "FAIL: empty S3 access key"; exit 1; }
[ -n "$S3_SECRET_KEY" ] || { echo "FAIL: empty S3 secret key"; exit 1; }
[ -n "$PROOF_KEY" ] || { echo "FAIL: openssl produced no proof key"; exit 1; }

cat > "$STAGE" <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: ocis-secrets
  namespace: files
type: Opaque
# stringData, not data - and that is a repo convention with a gate behind it, not a style preference.
# Every other Secret in apply/10-secrets uses stringData. `make dry-run` strips the sops envelope and
# submits the ciphertext as-is to mimic what kustomize-controller sends, and the API server
# base64-decodes `data` but never `stringData`. Measured: with `data:` the run died on
#   Error from server: failed to convert new object (files/ocis-secrets; /v1, Kind=Secret):
#     error decoding from json: illegal base64 data at input byte 3
# while the 24 existing stringData Secrets in the same stage passed. Values are plaintext here
# because sops encrypts this whole document on the next line.
stringData:
  admin-user: "$ADMIN_USER"
  admin-password: "$ADMIN_PASSWORD"
  jwt-secret: "$JWT_SECRET"
  machine-auth-api-key: "$MACHINE_AUTH_API_KEY"
  transfer-secret: "$TRANSFER_SECRET"
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
echo "Next: sops -d $TARGET | head -3 should print the plaintext Secret."
echo "Then: git add $TARGET and make check."
