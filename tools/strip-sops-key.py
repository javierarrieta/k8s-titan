#!/usr/bin/env python3
"""Strip the top-level `sops:` key from manifests on stdin, leaving everything else alone.

Why this exists: a sops-encrypted Secret carries a top-level `sops:` block (version, mac, the age
recipient). `kustomize build` passes it straight through, so the built object has a field the Secret
schema does not declare. Server-side apply refuses that outright:

    failed to create typed patch object (auth/authentik-secrets; /v1, Kind=Secret):
      .sops: field not declared in schema

kustomize-controller never sends it — it decrypts and drops the envelope before applying. That is
not an assumption: the `secrets` Kustomization reports `Ready=True / ReconciliationSucceeded` on the
live cluster with all seven of these Secrets in it, and the API server rejects the key on sight, so
the key provably does not reach it. Anything that dry-runs this tree against a real API server has to
make the same move, or it validates a document Flux would never submit and reports a failure that
does not exist.

Only `sops` is removed, and only at the top level of a mapping. Values are untouched — in particular
the `ENC[...]` ciphertext stays exactly as it is. That makes the output a faithful proxy for shape
validation: same name, same namespace, same keys, same string types. What it cannot check is whether
the plaintext behind the ciphertext is what a chart wants, and it does not claim to; `release-secrets`,
`db-url-check` and `oidc-check` are the gates that look at content.
"""
import sys

import yaml


def strip(stream_in, stream_out):
    docs = [d for d in yaml.safe_load_all(stream_in) if d is not None]
    removed = 0
    for doc in docs:
        if isinstance(doc, dict) and doc.pop("sops", None) is not None:
            removed += 1
    yaml.dump_all(docs, stream_out, default_flow_style=False, sort_keys=False)
    return removed


def main():
    try:
        removed = strip(sys.stdin, sys.stdout)
    except yaml.YAMLError as exc:
        print(f"strip-sops-key: input is not valid YAML: {exc}", file=sys.stderr)
        return 1
    if removed:
        print(f"strip-sops-key: dropped the sops envelope from {removed} document(s)", file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main())
