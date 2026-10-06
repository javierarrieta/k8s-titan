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

# kubectl apply warns once per live object that predates this repo's use of apply ("missing
# last-applied-configuration ... will be patched automatically"). Forty-odd warnings on a *passing*
# run is noise that trains you to skim, and skimming is how a real rejection gets missed.
#
# The filter is anchored on the `Warning: ` prefix on purpose. The first version grepped for
# `last-applied-configuration` anywhere in a line - and that string also appears inside the patch
# dump that accompanies a real rejection, so the filter ate the one line explaining the failure and
# left a wall of `Error from server (Invalid)` with no reason attached. A check that swallows its own
# diagnostics is worse than no check at all.
filter_noise() { grep -v '^Warning: ' || true; }

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
  # Server-side apply, because that is what kustomize-controller does. Client-side apply builds a
  # three-way merge from a last-applied-configuration annotation that Flux never writes, so every
  # Secret Flux had already created came back `Invalid` for reasons that had nothing to do with this
  # tree - a false positive from the checker, not a fault in the manifests, and it cost a merge
  # cycle to find. --force-conflicts matches the controller; a distinct field-manager keeps a
  # validation run from claiming ownership of anything it merely inspected.
  if kubectl kustomize "$root/apply/$stage" \
       | kubectl --context "$CTX" apply --server-side --force-conflicts \
           --field-manager=dry-run-check --dry-run=server -f - >/dev/null 2>"$err"; then
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
