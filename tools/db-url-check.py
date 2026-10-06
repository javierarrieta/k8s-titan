#!/usr/bin/env python3
"""db-url-check: assert the two copies of an app's DB password agree.

Coder takes one knob, CODER_PG_CONNECTION_URL, with the password inline. CloudNativePG's
declarative role takes a kubernetes.io/basic-auth Secret. Neither can be derived from the
other at apply time, so the same password is committed twice - and rotating one and forgetting
the other produces an authentication failure that reads like a database problem.

Driven by references found in the tree, not by a filename pattern, so it cannot pass vacuously
because something was renamed. For every HelmRelease env var named *PG_CONNECTION_URL it
resolves the referenced Secret and key, parses the URL, and compares against the DatabaseRole
whose role name equals the URL's user.

Fixtures may be plaintext; real secrets are sops-encrypted. A file that looks encrypted but
does not decrypt is reported, never silently skipped - a gate that skips is a gate that lies.
"""
import argparse
import base64
import os
import re
import subprocess
import sys
import urllib.parse

try:
    import yaml
except ImportError:
    sys.exit("db-url-check: PyYAML is missing (pip install pyyaml) - refusing to report clean")


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
                    sys.exit(f"db-url-check: cannot read {path}: {exc}")
            if "ENC[" in text and "sops:" in text:
                sys.exit(f"db-url-check: {path} looks sops-encrypted but did not decrypt "
                         f"(is SOPS_AGE_KEY_FILE set?) - refusing to report clean")
            try:
                docs = [d for d in yaml.safe_load_all(text) if isinstance(d, dict)]
            except yaml.YAMLError as exc:
                sys.exit(f"db-url-check: {path} is not valid YAML: {exc}")
            for d in docs:
                d["__path__"] = path
                out.append(d)
    return out


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


def pg_url_refs(docs):
    """(helmrelease-name, namespace, secret-name, key) for every *PG_CONNECTION_URL env ref."""
    refs = []
    for d in docs:
        if d.get("kind") != "HelmRelease":
            continue
        md = d.get("metadata") or {}
        values = ((d.get("spec") or {}).get("values") or {})
        for env in ((values.get("coder") or {}).get("env") or []):
            if not re.search(r"PG_CONNECTION_URL$", env.get("name", "")):
                continue
            ref = (env.get("valueFrom") or {}).get("secretKeyRef")
            if ref:
                refs.append((md.get("name"), md.get("namespace"), ref.get("name"), ref.get("key")))
    return refs


def roles(docs):
    """role name -> (DatabaseRole document, referenced passwordSecret name)."""
    out = {}
    for d in docs:
        if d.get("kind") == "DatabaseRole":
            spec = d.get("spec") or {}
            out[spec.get("name")] = (d, (spec.get("passwordSecret") or {}).get("name"))
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--root", default="apply")
    args = ap.parse_args()

    docs = load_docs(args.root)
    refs, roles_map, checked, bad = pg_url_refs(docs), roles(docs), 0, 0

    for hr_name, hr_ns, sec_name, key in refs:
        url, _ = secret_key(docs, sec_name, hr_ns or "coder", key)
        if url is None:
            print(f"FAIL: HelmRelease {hr_ns}/{hr_name} reads {sec_name}/{key}, "
                  f"which is not present under {args.root}")
            bad += 1
            continue
        u = urllib.parse.urlparse(url)
        if u.scheme not in ("postgres", "postgresql"):
            print(f"FAIL: {sec_name}/{key} is not a postgres URL (scheme {u.scheme!r})")
            bad += 1
            continue
        checked += 1
        user = urllib.parse.unquote(u.username or "")
        password = urllib.parse.unquote(u.password or "")
        entry = roles_map.get(user)
        if entry is None:
            print(f"FAIL: {sec_name}/{key} connects as {user!r}, but no DatabaseRole declares "
                  f"spec.name {user!r} - the URL points at a role nothing manages")
            bad += 1
            continue
        role_doc, cred_name = entry
        role_ns = (role_doc.get("metadata") or {}).get("namespace")
        cred_password, cdata = secret_key(docs, cred_name, role_ns, "password")
        if cdata is None:
            print(f"FAIL: DatabaseRole {user!r} references Secret {cred_name!r} in namespace "
                  f"{role_ns!r}, which is not under {args.root}")
            bad += 1
            continue
        if cdata.get("username") != user:
            print(f"FAIL: {cred_name} username is {cdata.get('username')!r}, not {user!r} - "
                  f"CNPG sets the password for a role nobody connects as")
            bad += 1
        if password != cred_password:
            print(f"FAIL: password in {sec_name}/{key} does not match {cred_name} - "
                  f"rotate both or neither")
            bad += 1

    print(f"db-url-check: {checked} PG URL reference(s) checked, {bad} mismatch(es)")
    sys.exit(1 if bad else 0)


if __name__ == "__main__":
    main()
