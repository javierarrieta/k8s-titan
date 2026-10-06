#!/usr/bin/env python3
"""kustomize-listing: every manifest under apply/ must be claimed by a kustomization.

Plain-directory fallback means `kustomize build` succeeds against a directory that lists nothing,
and then applies nothing from it. AGENTS.md requires explicit resource lists precisely so the tree
can be built offline - but an explicit list is also a list you can forget to update, and a forgotten
entry produces a manifest that is committed, reviewed, builds green, and is never applied. Flux has
no opinion about a file it was never told about.

This is not hypothetical: apply/50-apps/coder/coder-db.yaml was written, committed and left
unlisted, and nothing in the gate set noticed. `make secrets-placement` already does exactly this
job for Secrets; nothing did it for everything else.

Keyless and offline, so it belongs in check-ci as well as check.
"""
import os
import sys

try:
    import yaml
except ImportError:
    sys.exit("kustomize-listing: PyYAML is missing (pip install pyyaml) - refusing to report clean")


def claimed(kustomization_path):
    """Paths a kustomization claims, resolved relative to its own directory."""
    with open(kustomization_path) as fh:
        doc = yaml.safe_load(fh) or {}
    out = set()
    for key in ("resources", "components", "generators"):
        for entry in doc.get(key) or []:
            if not isinstance(entry, str):
                continue
            p = os.path.normpath(os.path.join(os.path.dirname(kustomization_path), entry))
            if os.path.isdir(p):
                for dirpath, _dirs, files in os.walk(p):
                    for fn in files:
                        if fn.endswith((".yaml", ".yml")) and fn != "kustomization.yaml":
                            out.add(os.path.normpath(os.path.join(dirpath, fn)))
            else:
                out.add(p)
    return out


def main():
    root = sys.argv[1] if len(sys.argv) > 1 else "apply"
    if not os.path.isdir(root):
        sys.exit(f"kustomize-listing: {root} is not a directory - refusing to report clean")

    kustomizations, manifests = [], []
    for dirpath, _dirs, files in os.walk(root):
        for fn in sorted(files):
            path = os.path.normpath(os.path.join(dirpath, fn))
            if fn == "kustomization.yaml":
                kustomizations.append(path)
            elif fn.endswith((".yaml", ".yml")):
                manifests.append(path)

    if not kustomizations:
        sys.exit(f"kustomize-listing: no kustomization.yaml under {root} - refusing to report "
                 f"clean, because 'nothing is listed' is not the same as 'everything is listed'")

    have = set()
    for k in kustomizations:
        have |= claimed(k)

    unlisted = sorted(m for m in manifests if m not in have)
    missing = sorted(p for p in have if not os.path.exists(p))

    for m in unlisted:
        print(f"FAIL: {m} is not listed in any kustomization.yaml - it builds green and is "
              f"silently never applied")
    for m in missing:
        print(f"FAIL: a kustomization.yaml lists {m}, which does not exist")

    print(f"kustomize-listing: {len(manifests)} manifest(s), {len(kustomizations)} "
          f"kustomization(s), {len(unlisted)} unlisted, {len(missing)} listed-but-missing")
    sys.exit(1 if (unlisted or missing) else 0)


if __name__ == "__main__":
    main()
