"""Shared YAML-under-sops loading for the agreement gates.

Both db-url-check and oidc-check need the same thing: every document under a tree, with
sops-encrypted files decrypted, and a refusal rather than a shrug when a file looks encrypted
but will not decrypt. Duplicating that would be ironic in a module whose callers exist to
police duplicated secrets.
"""
import base64
import os
import subprocess
import sys

try:
    import yaml
except ImportError:
    sys.exit("PyYAML is missing (pip install pyyaml) - refusing to report clean")


def load_docs(root):
    """Every YAML document under root, with its path. Secrets and CRs alike."""
    out = []
    for dirpath, _dirs, files in os.walk(root):
        for fn in sorted(files):
            if not fn.endswith((".yaml", ".yml")) or fn == "kustomization.yaml":
                continue
            path = os.path.join(dirpath, fn)
            try:
                text = subprocess.run(["sops", "--decrypt", path], capture_output=True,
                                      text=True, check=True).stdout
            except subprocess.CalledProcessError:
                try:
                    with open(path) as fh:
                        text = fh.read()
                except OSError as exc:
                    sys.exit(f"cannot read {path}: {exc}")
            if "ENC[" in text and "sops:" in text:
                sys.exit(f"{path} looks sops-encrypted but did not decrypt "
                         f"(is SOPS_AGE_KEY_FILE set?) - refusing to report clean")
            try:
                docs = [d for d in yaml.safe_load_all(text) if isinstance(d, dict)]
            except yaml.YAMLError as exc:
                sys.exit(f"{path} is not valid YAML: {exc}")
            for d in docs:
                d["__path__"] = path
                out.append(d)
    return out


def load_text(path):
    """Raw text of a file, decrypted if sops-encrypted. For byte-level comparisons."""
    try:
        return subprocess.run(["sops", "--decrypt", path], capture_output=True,
                              text=True, check=True).stdout
    except subprocess.CalledProcessError:
        pass
    if os.path.exists(path):
        with open(path) as fh:
            text = fh.read()
        if "ENC[" in text and "sops:" in text:
            sys.exit(f"{path} looks sops-encrypted but did not decrypt "
                     f"(is SOPS_AGE_KEY_FILE set?) - refusing to report clean")
        return text
    return None


def secret_key(docs, name, namespace, key):
    """(value, whole-string-data) for one Secret key, or (None, None) if absent."""
    for d in docs:
        if d.get("kind") != "Secret":
            continue
        md = d.get("metadata") or {}
        if md.get("name") != name or md.get("namespace") != namespace:
            continue
        data = d.get("stringData") or {}
        if not data:
            data = {k: base64.b64decode(v).decode() for k, v in (d.get("data") or {}).items()}
        return data.get(key), data
    return None, None


def find(docs, kind, name, namespace=None):
    for d in docs:
        if d.get("kind") != kind:
            continue
        md = d.get("metadata") or {}
        if md.get("name") != name:
            continue
        if namespace is not None and md.get("namespace") != namespace:
            continue
        return d
    return None
