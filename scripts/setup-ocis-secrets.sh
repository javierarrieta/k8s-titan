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

b64() { printf '%s' "$1" | base64 | tr -d '\n'; }

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
data:
  admin-user: $(b64 "$ADMIN_USER")
  admin-password: $(b64 "$ADMIN_PASSWORD")
  jwt-secret: $(b64 "$JWT_SECRET")
  machine-auth-api-key: $(b64 "$MACHINE_AUTH_API_KEY")
  s3-access-key: $(b64 "$S3_ACCESS_KEY")
  s3-secret-key: $(b64 "$S3_SECRET_KEY")
  collabora-admin-user: $(b64 "$COLLABORA_ADMIN_USER")
  collabora-admin-password: $(b64 "$COLLABORA_ADMIN_PASSWORD")
  collabora-proof-key: $(printf '%s\n' "$PROOF_KEY" | base64 | tr -d '\n')
EOF

sops --encrypt --in-place "$STAGE"
mv "$STAGE" "$TARGET"
trap - EXIT

echo "wrote $TARGET"
echo "sha256 ${TARGET}: $(sha256sum "$TARGET" | cut -c1-16)"
echo
echo "Next: sops -d $TARGET | head -3 should print the plaintext Secret."
echo "Then: git add $TARGET and make check."
