#!/usr/bin/env python3
"""Assert every field in a built manifest is declared in its CRD's schema.

Reads multi-document YAML on stdin (the output of `kubectl kustomize`), CRDs from a
directory given as argv[1], and reports any object key that the CRD does not declare at
that exact position.

Why this exists and jsonschema does not: the CNPG CRDs set no `additionalProperties:
false` anywhere, so a schema validator reports a mis-nested field as VALID. Only the API
server's typed-patch path rejects it, and it does so at reconcile time - which is how
`spec.backup.barmanObjectStore.retentionPolicy` (a child of spec.backup, not of
barmanObjectStore) blocked the whole apps stage on a live cluster. This walk reproduces
that rejection offline, and reports the same path the server reports.

Subtrees marked x-kubernetes-preserve-unknown-fields are skipped: the server accepts
anything there, so flagging them would be a false positive.
"""
import sys
import yaml


def load_schemas(directory):
    import glob
    import os
    schemas = {}
    for path in sorted(glob.glob(os.path.join(directory, "*.yaml"))):
        with open(path) as fh:
            for doc in yaml.safe_load_all(fh):
                if not doc or doc.get("kind") != "CustomResourceDefinition":
                    continue
                versions = doc["spec"]["versions"]
                version = next((v for v in versions if v.get("storage")), versions[-1])
                schemas[doc["spec"]["names"]["kind"]] = version["schema"]["openAPIV3Schema"]
    return schemas


def walk(node, schema, path, out):
    if schema is None or node is None:
        return
    if isinstance(node, list):
        items = schema.get("items")
        if items:
            for i, element in enumerate(node):
                walk(element, items, path + [i], out)
        return
    if not isinstance(node, dict):
        return
    if schema.get("x-kubernetes-preserve-unknown-fields"):
        return
    props = schema.get("properties")
    extra = schema.get("additionalProperties")
    if props is None:
        if isinstance(extra, dict):
            for key, value in node.items():
                walk(value, extra, path + [key], out)
        return
    for key, value in node.items():
        if key in props:
            walk(value, props[key], path + [key], out)
        elif isinstance(extra, dict):
            walk(value, extra, path + [key], out)
        else:
            out.append(".".join(str(p) for p in path + [key]))


def main():
    try:
        schemas = load_schemas(sys.argv[1])
    except (OSError, IndexError) as exc:
        print(f"crd-check: cannot load CRDs from {sys.argv[1] if len(sys.argv) > 1 else '<unset>'}: {exc}")
        return 2
    if not schemas:
        print(f"crd-check: no CRDs found in {sys.argv[1]} - refusing to report clean")
        return 2

    checked, failures, kinds = 0, [], set()
    for obj in yaml.safe_load_all(sys.stdin.read()):
        if not isinstance(obj, dict) or "kind" not in obj:
            continue
        if obj["kind"] not in schemas:
            continue
        kinds.add(obj["kind"])
        checked += 1
        out = []
        walk(obj, schemas[obj["kind"]], [], out)
        for field in out:
            failures.append(f"{obj['kind']}/{obj['metadata']['name']}: {field}")

    if checked == 0:
        print(f"crd-check: 0 objects matched the vendored CRDs ({', '.join(sorted(schemas))}) "
              f"- refusing to report clean")
        return 2
    if failures:
        print("FAIL: fields not declared in the CRD schema (the API server rejects these at "
              "reconcile time, not at build time):")
        for f in failures:
            print(f"  {f}")
        return 1
    print(f"crd-check: {checked} object(s) checked against {len(schemas)} vendored CRD(s) "
          f"({', '.join(sorted(kinds))} seen); every field declared")
    return 0


if __name__ == "__main__":
    sys.exit(main())
