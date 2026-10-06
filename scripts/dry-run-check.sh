#!/usr/bin/env bash
# dry-run-check.sh — ask the real API server whether it would accept every object this tree builds.
#
# Why this exists: a PersistentVolumeClaim LimitRange with `default` and no `max` is invalid. It
# passed `kustomize build`, passed every offline gate, and passed review — then took the whole `apps`
# stage down on merge, because kustomize-controller server-dry-runs every object and aborts the
# stage on the first rejection. Nothing vendored in this repo knows that rule: no CRD covers core
# types, and the OpenAPI schema does not encode it. The API server is the only authority.
#
# Needs write authorization for what it validates, so the read-only k8s-reader identity cannot run
# it (it answers Forbidden — checked, not assumed). That is why `make check` does not run it and why
# this skips out loud instead of passing vacuously.
#
#   scripts/dry-run-check.sh <admin kube context>
#   make dry-run DRYRUN_CONTEXT=<admin kube context>
set -euo pipefail

STAGES=(00-bootstrap 10-secrets 20-infra 40-certificates 50-apps)

# kubectl apply --dry-run=server warns once per live object that predates this repo's use of apply
# ("last-applied-configuration ... will be patched automatically"). Forty-odd warnings on a *passing*
# run is noise that trains you to skim the output, and skimming is how a real rejection gets missed.
# They are filtered; everything else, including every error, is passed through untouched.
filter_noise() { grep -v 'last-applied-configuration' || true; }

if [[ $# -ne 1 || -z "${1:-}" ]]; then
  echo "dry-run: SKIPPED — pass an admin kube context: scripts/dry-run-check.sh <context>" >&2
  echo "dry-run: this is the only check that can catch core-type validation rules no schema here knows" >&2
  exit 0
fi
CTX="$1"

command -v kubectl >/dev/null || { echo "FAIL: kubectl not on PATH" >&2; exit 1; }
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

err=$(mktemp); trap 'rm -f "$err"' EXIT
checked=0
for stage in "${STAGES[@]}"; do
  printf '%-18s ' "$stage"
  # The build is piped, not staged to a file, so what gets validated is exactly what Flux would apply.
  if kubectl kustomize "$root/apply/$stage" | kubectl --context "$CTX" apply --dry-run=server -f - >/dev/null 2>"$err"; then
    filter_noise <"$err" >&2
    echo "ok"
    checked=$((checked + 1))
  else
    echo "REJECTED"
    filter_noise <"$err" >&2
    echo "" >&2
    echo "dry-run: $stage rejected by the API server (exit non-zero; nothing from this tree would apply)" >&2
    exit 1
  fi
done

echo "dry-run: ${#STAGES[@]} stage(s) built, $checked accepted by the API server"
