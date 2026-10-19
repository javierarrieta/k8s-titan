#!/usr/bin/env bash
# Re-vendor the CRD schemas that `make crd-check` validates against, for the API groups
# beyond CNPG (which has its own tag-pinned target, `make update-cnpg-crds`).
#
# Why this reads the CRDs from a live cluster instead of downloading them from upstream:
#
#   1. It is the only way to get Traefik's. Traefik ships its CRDs inside a release
#      tarball, not at a stable raw URL, and k3s installs them from rancher's mirror —
#      so "the version upstream" and "the version this cluster enforces" are not the same
#      object, and only one of them is the one that will reject our manifest.
#   2. The gate's whole job is to predict what the API server will reject. Vendoring from
#      the API server removes the guess.
#
# The consequence, stated plainly: this needs cluster access, so it is a laptop operation,
# not a CI one. The files it writes are committed, so `make crd-check` itself stays offline
# and deterministic — CI never runs this script.
#
# Usage: scripts/update-crds.sh [context]     (default: the k8s-reader context for titan)
set -euo pipefail

CTX="${1:-k8s-titan}"
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# group-dir  ->  CRD names to vendor from it.
# Named CRD_GROUPS, not GROUPS: GROUPS is a bash builtin holding the caller's group IDs and
# silently refuses assignment, so `GROUPS=(...)` leaves it as the GID list and the loop below
# vendored a CRD named "1000" instead. Measured, not guessed.
CRD_GROUPS=(
  "flux-crds kustomizations.kustomize.toolkit.fluxcd.io helmreleases.helm.toolkit.fluxcd.io"
  "cert-manager-crds certificates.cert-manager.io"
  "traefik-crds middlewares.traefik.io ingressroutetcps.traefik.io"
)

if ! kubectl --context "$CTX" auth can-i get customresourcedefinitions >/dev/null 2>&1; then
  echo "update-crds: context '$CTX' cannot read CRDs. Use a read-only context that can" >&2
  echo "update-crds: (k8s-reader can; it needs no admin). Refusing to write anything." >&2
  exit 1
fi

total=0
for spec in "${CRD_GROUPS[@]}"; do
  set -- $spec
  dir="vendor/$1"; shift
  mkdir -p "$REPO/$dir"
  for crd in "$@"; do
    plural="${crd%%.*}"
    if ! kubectl --context "$CTX" get crd "$crd" -o yaml > "$REPO/$dir/$plural.yaml.tmp" 2>/dev/null; then
      echo "update-crds: FAILED to read $crd via $CTX" >&2
      rm -f "$REPO/$dir/$plural.yaml.tmp"
      exit 1
    fi
    # Strip the live-object noise so the diff is the schema and nothing else.
    python3 - "$REPO/$dir/$plural.yaml.tmp" "$REPO/$dir/$plural.yaml" <<'PY'
import sys, yaml
src, dst = sys.argv[1], sys.argv[2]
with open(src) as fh:
    doc = yaml.safe_load(fh)
for key in ("metadata", "status"):
    if key in doc:
        for noise in ("creationTimestamp", "managedFields", "resourceVersion", "uid",
                      "generation", "annotations", "observedGeneration", "conditions",
                      "storedVersions", "acceptedNames"):
            doc[key].pop(noise, None)

# Prose is dropped on purpose, and it took the repo's own gate to say why. crd-field-check
# walks properties/items/additionalProperties only — it never reads a description — so
# carrying them buys nothing and costs two things. The first is size. The second is that
# cert-manager's Certificate schema spells certificate policy OIDs — four-part dotted
# decimals, not addresses — inside its descriptions, and `make leak-check`'s IPv4 pattern
# reads those as concrete public IPv4s. The gate was not wrong to fire; the vendored file
# had no business containing prose. Stripping it removes the false positive without touching
# the leak gate, which is the opposite of the usual way this gets "fixed".
# (The gate then fired a second time on this very script, because the OIDs were quoted here
# as literals. Do not put a dotted quad back in this file; describe it instead.)
PROSE = ("description", "examples", "example")
def strip_prose(node):
    if isinstance(node, dict):
        for key in PROSE:
            node.pop(key, None)
        for value in node.values():
            strip_prose(value)
    elif isinstance(node, list):
        for value in node:
            strip_prose(value)
strip_prose(doc)

with open(dst, "w") as fh:
    yaml.safe_dump(doc, fh, sort_keys=False, width=100000)
PY
    rm -f "$REPO/$dir/$plural.yaml.tmp"
    bytes=$(wc -c < "$REPO/$dir/$plural.yaml")
    total=$((total + bytes))
    printf '  %-28s %7s bytes\n' "$dir/$plural.yaml" "$bytes"
  done
  {
    echo "# Vendored from the live cluster via the read-only identity, $(date -u +%FT%TZ)."
    echo "# Source context: $CTX. This is the schema the API server enforces today, not an"
    echo "# upstream tag — see the header of scripts/update-crds.sh for why."
  } > "$REPO/$dir/VERSION"
done

echo "update-crds: wrote $total bytes across ${#CRD_GROUPS[@]} group(s) via $CTX"
echo "update-crds: commit the result; crd-check reads the committed files, never the cluster"
