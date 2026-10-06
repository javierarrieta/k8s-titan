#!/usr/bin/env bash
# Rotate the AWS credentials behind apply/10-secrets/s3-backup-secrets.yaml.
#
# RUN IT, DON'T READ IT INTO A SHELL. The shebang makes your login shell irrelevant, which
# is the whole reason this is a script and not a block in the runbook: the bash form uses
# `export VAR=`, `read -rs -p` and `[[ =~ ]]`, and all three mean something different - or
# nothing - in fish. Copy-pasting it into fish fails in ways that look like a broken repo.
#
# Why it prompts instead of taking arguments: this credential is being rotated *because* the
# previous one was pasted into a chat transcript. Arguments land in shell history and in
# scrollback-to-paste range; a prompt lands in neither. Nothing here prints a value - the
# before/after comparison is a truncated SHA-256, not the secret.
#
# Create-then-delete, always:
#   1. create the second IAM access key for k8s-titan-pg-backups
#   2. ./scripts/rotate-s3-backup-key.sh
#   3. make check, commit, merge
#   4. prove WAL is still archiving - pg_stat_archiver, docs/authentik-runbook.md S1
#   5. only then delete the old key in IAM
# Deleting first leaves the cluster archiving to a bucket it can no longer write to, and the
# failure is silent until the WAL volume fills.
set -euo pipefail

REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$REPO"

SECRET_FILE=${SECRET_FILE:-apply/10-secrets/s3-backup-secrets.yaml}
# git-ignored, and under apply/10-secrets/ so .sops.yaml's path_regex picks the right
# recipients - sops chooses recipients from the file's own path, not from your intent.
STAGE=apply/10-secrets/.staging.s3-backup.yaml
KEY=${SOPS_AGE_KEY_FILE:-$HOME/.config/sops/age/titan-k8s-key.txt}

# Never leave plaintext behind, whatever fails.
trap 'rm -f "$STAGE"' EXIT

for tool in sops python3; do
  command -v "$tool" >/dev/null || { echo "FAIL: $tool not on PATH"; exit 1; }
done
[ -f "$KEY" ]         || { echo "FAIL: no age key at $KEY - set SOPS_AGE_KEY_FILE"; exit 1; }
[ -f "$SECRET_FILE" ] || { echo "FAIL: $SECRET_FILE not found - run this from a k8s-titan checkout"; exit 1; }
export SOPS_AGE_KEY_FILE="$KEY"

# A comparison handle, never the value. The access key ID is an identifier and prints in
# full; the secret access key prints as 12 hex characters of its SHA-256.
fingerprint() {
  sops -d "$1" | python3 -c '
import sys, yaml, hashlib
sd = yaml.safe_load(sys.stdin.read())["stringData"]
ak = sd["ACCESS_KEY_ID"]; sk = sd["SECRET_ACCESS_KEY"]; rg = sd["AWS_REGION"]
print("  ACCESS_KEY_ID      " + ak[:4] + "..." + ak[-4:])
print("  SECRET_ACCESS_KEY  sha256:" + hashlib.sha256(sk.encode()).hexdigest()[:12])
print("  AWS_REGION         " + rg)' 2>/dev/null || { echo "  (could not decrypt $1 - wrong age key?)"; exit 1; }
}

echo "== current credential (fingerprint only)"
fingerprint "$SECRET_FILE"

read -rs -p "new ACCESS_KEY_ID: "     AKID;    echo
read -rs -p "new SECRET_ACCESS_KEY: " ASecret; echo

# Guards BEFORE encrypting. An empty or truncated value encrypts perfectly and fails three
# namespaces away - the same class that once produced two empty authentik passwords.
if [[ ! "$AKID" =~ ^AKIA[0-9A-Z]{16}$ ]]; then
  echo "FAIL: ACCESS_KEY_ID is not AKIA + 16 uppercase alphanumerics (got ${#AKID} chars)"; exit 1
fi
if [[ ! "$ASecret" =~ ^[A-Za-z0-9/+=]{40}$ ]]; then
  echo "FAIL: SECRET_ACCESS_KEY is not 40 chars of [A-Za-z0-9/+=] (got ${#ASecret})"; exit 1
fi

cat > "$STAGE" <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: s3-backup-secrets
  namespace: databases
type: Opaque
stringData:
  ACCESS_KEY_ID: "$AKID"
  SECRET_ACCESS_KEY: "$ASecret"
  AWS_REGION: eu-west-1
EOF
unset AKID ASecret

# AWS_REGION is not decoration: s3Credentials.region is a secret-key reference and there is
# no EC2 instance metadata on titan for barman to fall back to. It must survive every rewrite.
sops --encrypt --in-place "$STAGE"
mv "$STAGE" "$SECRET_FILE"

echo "== new credential (fingerprint only)"
fingerprint "$SECRET_FILE"

cat <<'EOF'

Next, in this order. Do not delete the old IAM key until step 4 passes.

  1. git add apply/10-secrets/s3-backup-secrets.yaml
  2. make check            # decrypt + placement + the rest of the offline gates
  3. git commit && merge to main, let Flux apply it
  4. prove archiving advanced:
       kubectl -n databases exec postgres-1 -c postgres -- \
         psql -U postgres -Atc "select archived_count, failed_count from pg_stat_archiver"
       kubectl -n databases exec postgres-1 -c postgres -- psql -U postgres -Atc "select pg_switch_wal()"
       sleep 20
       kubectl -n databases exec postgres-1 -c postgres -- \
         psql -U postgres -Atc "select archived_count, last_archived_wal, failed_count from pg_stat_archiver"
     archived_count up and failed_count flat = the new key works. On CNPG 1.30.1 the new
     credentials propagated without a pod roll (observed 2026-10-05: pod older than the
     Secret, archiving clean), so if failed_count moves, look for another cause first.
     If it really is stale credentials (cloudnative-pg#4914):
       kubectl -n databases delete pod postgres-1
     Single instance, so that is a few seconds of write outage - a response to stalled
     archiving, not a post-merge reflex.
  5. delete the OLD access key in IAM.
EOF
