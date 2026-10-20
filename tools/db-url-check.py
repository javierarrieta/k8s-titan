#!/usr/bin/env python3
"""db-url-check: assert the two copies of an app's DB password agree.

Coder takes one knob, CODER_PG_CONNECTION_URL, with the password inline. CloudNativePG's
declarative role takes a kubernetes.io/basic-auth Secret. Neither can be derived from the
other at apply time, so the same password is committed twice - and rotating one and forgetting
the other produces an authentication failure that reads like a database problem.

Driven by references found in the tree, not by a filename pattern, so it cannot pass vacuously
because something was renamed. Two shapes are walked, because this cluster has both: a HelmRelease
env named *PG_CONNECTION_URL (coder), and a Deployment's DATABASE_URL — whether it arrives as an
explicit `valueFrom.secretKeyRef` or through `envFrom` on the Secret that carries it (open-webui).
A finder that walks only one shape reports zero references for the other and passes vacuously, which
is the one failure mode a reference-driven gate must never have.

Fixtures may be plaintext; real secrets are sops-encrypted. A file that looks encrypted but
does not decrypt is reported, never silently skipped - a gate that skips is a gate that lies.
"""
import argparse
import os
import re
import sys
import urllib.parse

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from sopsload import load_docs, secret_key  # noqa: E402


def pg_url_refs(docs):
    """(workload-name, namespace, secret-name, key) for every Postgres URL env ref.

    Two shapes, because this cluster has both. Coder takes one knob, CODER_PG_CONNECTION_URL, in a
    HelmRelease's values; open-webui takes DATABASE_URL on a Deployment, and reads it through
    `envFrom` rather than naming the key. The envFrom walk is what makes the second one visible:
    a Secret is only a reference if something reads it, so the walk starts from the workload and
    asks the Secret whether it carries a URL, never the other way round.
    """
    refs = []
    secrets_by_ns = {}
    for d in docs:
        if d.get("kind") == "Secret":
            md = d.get("metadata") or {}
            secrets_by_ns.setdefault(md.get("namespace"), {})[md.get("name")] = d

    for d in docs:
        kind = d.get("kind")
        md = d.get("metadata") or {}
        if kind == "HelmRelease":
            values = ((d.get("spec") or {}).get("values") or {})
            for env in ((values.get("coder") or {}).get("env") or []):
                if not re.search(r"PG_CONNECTION_URL$", env.get("name", "")):
                    continue
                ref = (env.get("valueFrom") or {}).get("secretKeyRef")
                if ref:
                    refs.append((md.get("name"), md.get("namespace"), ref.get("name"), ref.get("key")))
        elif kind == "Deployment":
            for c in (((d.get("spec") or {}).get("template") or {}).get("spec") or {}).get("containers", []):
                for env in c.get("env") or []:
                    if not re.search(r"(PG_CONNECTION_URL|DATABASE_URL)$", env.get("name", "")):
                        continue
                    ref = (env.get("valueFrom") or {}).get("secretKeyRef")
                    if ref:
                        refs.append((md.get("name"), md.get("namespace"), ref.get("name"), ref.get("key")))
                for ef in c.get("envFrom") or []:
                    name = (ef.get("secretRef") or {}).get("name")
                    if not name:
                        continue
                    sec = secrets_by_ns.get(md.get("namespace"), {}).get(name)
                    if sec is None:
                        continue
                    for key in ("DATABASE_URL", "PG_CONNECTION_URL"):
                        if key in (sec.get("stringData") or {}) or key in (sec.get("data") or {}):
                            refs.append((md.get("name"), md.get("namespace"), name, key))
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

    for wl_name, ns, sec_name, key in refs:
        url, _ = secret_key(docs, sec_name, ns or "default", key)
        if url is None:
            print(f"FAIL: {wl_name} reads {sec_name}/{key}, "
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
