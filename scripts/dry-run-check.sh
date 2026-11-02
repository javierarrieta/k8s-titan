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

# Derived from the tree, never listed by hand.
#
# This was a hardcoded list, and it went stale twice without anyone noticing: `30-databases` and
# `60-tesla` were added as stages and never added here, so the CNPG `Cluster`, the ScheduledBackup
# and all of TeslaMate have never been asked whether the API server would accept them. Worse than
# failing, the run printed `dry-run: 5 stage(s) built, 5 accepted by the API server` - a pass, over
# a subset. That is the same class of bug `make kustomize-listing` exists for on the Flux side: a
# gate whose input list is maintained by hand will be maintained by hand once too often.
#
# A stage is any directory under apply/ carrying a kustomization.yaml, which is exactly what Flux
# builds, so the gate can no longer drift from the tree.
STAGES=()

# kubectl apply warns once per live object that predates this repo's use of apply ("missing
# last-applied-configuration ... will be patched automatically"). Forty-odd warnings on a *passing*
# run is noise that trains you to skim, and skimming is how a real rejection gets missed.
#
# The filter is anchored on the `Warning: ` prefix on purpose. The first version grepped for
# `last-applied-configuration` anywhere in a line — and that string also appears inside the patch
# dump that accompanies a real rejection, so the filter ate the one line explaining the failure and
# left a wall of `Error from server (Invalid)` with no reason attached. A check that swallows its own
# diagnostics is worse than no check at all.
filter_noise() { grep -v '^Warning: ' || true; }

# new_namespace_gap <stage> <errfile> — exit 0 when a stage's ONLY failures are objects placed in a
# namespace that this tree declares (in this stage or an earlier one) and the cluster does not have
# yet. That is not a defect in the manifests; it is a limit of asking the API server about something
# that does not exist.
#
# Measured 2026-10-31 on PR #211: `20-infra` was rejected with two
# `Error from server (NotFound): namespaces "traefik-system" not found` lines - the HelmRepository and
# the HelmRelease - on a tree that would have applied fine, because Flux applies 00-bootstrap before
# 20-infra for real and server-side dry-run persists nothing. The Namespace is accepted and then is
# not there for the objects that follow it, even inside a single invocation, so declaring it in the
# same stage as its consumers does not help; it only moves the failure. The fix was to land the
# namespace first as its own change (#212). This function exists so the gate says that instead of
# going red, because a red gate on a correct tree trains you to run the gate with the flag that
# ignores it.
#
# It is deliberately narrow, and each condition is load-bearing:
#   - EVERY error line must be of this form. One unrelated rejection and the stage is judged on its
#     real failure, not waved through because a namespace was also missing.
#   - The namespace must be declared by the tree, in this stage or an earlier one. A typo'd namespace
#     is a real bug and stays red. (namespace-check catches that class separately; this is defence in
#     depth, not the only line.)
#   - The cluster must not already have it. If it does, a NotFound naming it means something else.
new_namespace_gap() {
  local stage="$1" errfile="$2" total ns_total ns
  total=$(grep -c '^Error from server' "$errfile" 2>/dev/null || true)
  [ "${total:-0}" -gt 0 ] || return 1
  ns_total=$(grep -cE '^Error from server \(NotFound\): namespaces "[^"]+" not found$' "$errfile" 2>/dev/null || true)
  [ "${ns_total:-0}" -eq "${total}" ] || return 1
  for ns in $(sed -n 's/^Error from server (NotFound): namespaces "\([^"]*\)" not found$/\1/p' "$errfile" | sort -u); do
    kubectl --context "$CTX" get namespace "$ns" >/dev/null 2>&1 && return 1
    namespace_declared_upto "$stage" "$ns" || return 1
  done
  return 0
}

# Walks stages in Flux's own order and stops at the failing one - a namespace first declared in a
# LATER stage is an ordering bug, and an ordering bug should stay red.
namespace_declared_upto() {
  local upto="$1" want="$2" stage
  for stage in "${STAGES[@]}"; do
    if kubectl kustomize "$root/apply/$stage" 2>/dev/null \
       | python3 -c 'import sys, yaml
for d in yaml.safe_load_all(sys.stdin):
    if d and d.get("kind") == "Namespace" and d.get("metadata", {}).get("name") == sys.argv[1]:
        sys.exit(0)
sys.exit(1)' "$want"; then
      return 0
    fi
    [ "$stage" = "$upto" ] && break
  done
  return 1
}

count_objects() {
  python3 -c 'import sys, yaml; print(len([d for d in yaml.safe_load_all(open(sys.argv[1])) if d]))' "$1"
}

if [[ $# -ne 1 || -z "${1:-}" ]]; then
  echo "dry-run: SKIPPED — pass an admin kube context: scripts/dry-run-check.sh <context>" >&2
  echo "dry-run: this is the only check that can catch core-type validation rules no schema here knows" >&2
  exit 0
fi
CTX="$1"

command -v kubectl >/dev/null || { echo "FAIL: kubectl not on PATH" >&2; exit 1; }
command -v python3 >/dev/null || { echo "FAIL: python3 not on PATH (the stripper needs it, and PyYAML — see make py-deps)" >&2; exit 1; }
# Existence of the interpreter is not the same as the import working, and the difference is invisible.
# Both the stripper and count_objects send their tracebacks into $err, and the EXIT trap below
# deletes that file - so under `set -e` a missing PyYAML made this gate print one stage label, exit
# 1, and destroy its own evidence. Measured 2026-10-28 in a nix-shell that had python3 but not
# python3Packages.pyyaml: `00-bootstrap` and nothing else. Same probe `make py-deps` already uses,
# run before any work so the failure names the missing package instead of a stage name.
python3 -c 'import yaml' 2>/dev/null || { \
  echo "FAIL: python3 has no PyYAML - the sops stripper cannot run, and a partial validation is worse than none." >&2; \
  echo "FAIL:   install it:  nix-shell -p python3 python3Packages.pyyaml   (see also: make py-deps)" >&2; \
  exit 1; }
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

for k in "$root"/apply/*/kustomization.yaml; do
  [ -e "$k" ] || continue
  STAGES+=("$(basename "$(dirname "$k")")")
done
if [ "${#STAGES[@]}" -eq 0 ]; then
  echo "dry-run: FAIL - no stage under $root/apply has a kustomization.yaml; refusing to report a clean run over nothing" >&2
  exit 1
fi

err=$(mktemp); trap 'rm -f "$err"' EXIT
checked=0
skipped_stages=()
for stage in "${STAGES[@]}"; do
  printf '%-18s ' "$stage"
  built=$(mktemp); stripped=$(mktemp)
  trap 'rm -f "$err" "$built" "$stripped"' EXIT

  if ! kubectl kustomize "$root/apply/$stage" >"$built" 2>"$err"; then
    echo "BUILD FAILED"
    filter_noise <"$err" >&2
    exit 1
  fi

  # The stripper removes the top-level `sops:` key that a sops Secret carries and the Secret schema
  # does not declare, which server-side apply otherwise refuses outright. Flux decrypts and drops that
  # envelope before submitting, so dry-running it unstripped validates a document that will never be
  # sent. tools/strip-sops-key.py records why that is known rather than assumed.
  python3 "$root/tools/strip-sops-key.py" <"$built" >"$stripped" 2>>"$err"

  # Object-count guard, and it is not paranoia. The stdlib-only alternative to this stripper was
  # `kubectl create --dry-run=client -o json`, which needs cluster discovery to build its RESTMapper;
  # run as the read-only identity, Forbidden on postgresql.cnpg.io, it dropped all six CNPG objects
  # out of a fifteen-object stage and exited clean. Four of five stages matched counts, which is
  # precisely how that would have gone unnoticed. A gate that validates a subset and prints "ok" is
  # worse than one that fails loudly over a missing package — and `make py-deps` already turns that
  # into an instruction, so the tidy version was never buying anything.
  n_in=$(count_objects "$built"); n_out=$(count_objects "$stripped")
  if [ "$n_in" -ne "$n_out" ]; then
    echo "REJECTED"
    echo "dry-run: stripper emitted $n_out object(s) for $n_in built — refusing to report a partial validation" >&2
    exit 1
  fi

  # Server-side apply, because that is what kustomize-controller does. Client-side apply builds a
  # three-way merge from a last-applied-configuration annotation that Flux never writes, so every
  # Secret Flux had already created came back `Invalid` for reasons that had nothing to do with this
  # tree — a false positive from the checker, not a fault in the manifests, and it cost a merge cycle
  # to find. --force-conflicts matches the controller; a distinct field-manager keeps a validation
  # run from claiming ownership of anything it merely inspected.
  if kubectl --context "$CTX" apply --server-side --force-conflicts \
         --field-manager=dry-run-check --dry-run=server -f "$stripped" >/dev/null 2>"$err"; then
    filter_noise <"$err" >&2
    echo "ok ($n_out objects)"
    checked=$((checked + 1))
  else
    if new_namespace_gap "$stage" "$err"; then
      echo "SKIPPED — not validated (new namespace not live yet)"
      skipped_stages+=("$stage")
      filter_noise <"$err" >&2
      continue
    fi
    echo "REJECTED"
    filter_noise <"$err" >&2
    echo "" >&2
    echo "dry-run: $stage rejected by the API server (exit non-zero; nothing from this tree would apply)" >&2
    exit 1
  fi
done

if [ "${#skipped_stages[@]}" -gt 0 ]; then
  echo "" >&2
  echo "dry-run: ${#STAGES[@]} stage(s) built, $checked accepted, ${#skipped_stages[@]} SKIPPED: ${skipped_stages[*]}" >&2
  echo "dry-run: A SKIPPED STAGE WAS NOT CHECKED. It places objects in a namespace this tree declares" >&2
  echo "dry-run:   that the cluster does not have yet, and server-side dry-run cannot create what a" >&2
  echo "dry-run:   later dry-run needs. Land the Namespace as its own change first, then re-run." >&2
  echo "dry-run:   This is the one case the gate cannot validate from inside; it is not a pass." >&2
else
  echo "dry-run: ${#STAGES[@]} stage(s) built, $checked accepted by the API server"
fi
