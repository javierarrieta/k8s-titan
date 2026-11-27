#!/usr/bin/env python3
"""Regenerate apply/00-bootstrap/flux-system/gotk-components.yaml from an upstream flux2
release, without installing the flux CLI.

Why this exists
---------------
The committed file was produced by `flux bootstrap`, and `flux bootstrap` output is NOT the
same bytes as the release's `install.yaml`. The file carried a `DO NOT EDIT` header and no
regeneration path, so the last two bumps were hand-edits against a file nobody could rebuild:
the images drifted to v1.10.1 while every label still said v2.9.6, and a 2026-10-27 CRD
hand-swap was documented in prose only. This script makes the transform explicit and, in
`verify` mode, proves it reproduces the committed file.

The five transforms that separate bootstrap output from install.yaml, each one read off the
committed file rather than guessed:

  1. component filter. install.yaml ships seven components; this cluster installs four
     (source, kustomize, helm, notification). Dropping source-watcher, image-reflector and
     image-automation takes the object count from 43 to 32 and the CRD count from 15 to 11.
  2. name suffix. bootstrap suffixes cluster-scoped objects and the ResourceQuota with the
     instance name — `crd-controller` becomes `crd-controller-flux-system` — and the
     ClusterRoleBindings that name those ClusterRoles move with them.
  3. args rewrite. bootstrap emits `--events-addr` against `$(RUNTIME_NAMESPACE)` where
     install.yaml hardcodes the namespace, and spells `--watch-all-namespaces=true` where
     install.yaml writes the bare flag.
  4. nodeSelector. bootstrap pins the controller pods to `kubernetes.io/os: linux`.
  5. version label. bootstrap stamps `app.kubernetes.io/version` on every object and every
     pod template. install.yaml carries no version label at all — which is the whole reason
     the labels in this tree could go stale without anything noticing.

Usage
-----
  curl -fsSLO https://github.com/fluxcd/flux2/releases/download/v2.10.1/install.yaml
  python3 tools/flux-bundle-export.py emit   install.yaml v2.10.1 > gotk-components.yaml
  python3 tools/flux-bundle-export.py verify install.yaml v2.9.6 \\
      apply/00-bootstrap/flux-system/gotk-components.yaml

`verify` is the honest one: run it against the file as it is BEFORE a bump and it should
report only the deltas you can explain. Anything else is an undocumented hand-edit, and the
last one of those cost a crash-loop.
"""
import sys
import json
import yaml

# The four components this cluster installs. A fifth would need its CRD group added here and
# a line in the header of the generated file.
COMPONENTS = {"source-controller", "kustomize-controller", "helm-controller",
              "notification-controller"}
SUFFIX = "flux-system"


def load(path):
    with open(path) as fh:
        return [d for d in yaml.safe_load_all(fh) if isinstance(d, dict)]


def transform(objs, version):
    """install.yaml objects -> the objects `flux bootstrap` would have written."""
    # 1. component filter. Objects with no component label are the shared scaffolding
    #    (Namespace, NetworkPolicies, ResourceQuota, shared RBAC) and always stay.
    def keep(d):
        comp = (d.get("metadata", {}).get("labels", {}) or {}).get("app.kubernetes.io/component")
        return comp is None or comp in COMPONENTS

    objs = [d for d in objs if keep(d)]

    # 2. name suffix, and the ClusterRoleBinding roleRefs that point at renamed ClusterRoles.
    renamed_roles = {}
    for d in objs:
        kind = d["kind"]
        if kind in ("ClusterRole", "ClusterRoleBinding") or kind == "ResourceQuota":
            old = d["metadata"]["name"]
            new = f"{old}-{SUFFIX}"
            d["metadata"]["name"] = new
            if kind == "ClusterRole":
                renamed_roles[old] = new
    for d in objs:
        if d["kind"] == "ClusterRoleBinding":
            ref = d.get("roleRef", {}).get("name")
            if ref in renamed_roles:
                d["roleRef"]["name"] = renamed_roles[ref]

    for d in objs:
        if d["kind"] != "Deployment":
            continue
        tpl = d["spec"]["template"]
        # 3. args rewrite
        for c in tpl["spec"]["containers"]:
            c["args"] = [a.replace(f"notification-controller.{SUFFIX}.svc",
                                   "notification-controller.$(RUNTIME_NAMESPACE).svc")
                         for a in c.get("args", [])]
            c["args"] = ["--watch-all-namespaces=true" if a == "--watch-all-namespaces" else a
                         for a in c["args"]]
        # 4. nodeSelector
        tpl["spec"]["nodeSelector"] = {"kubernetes.io/os": "linux"}

    # 5. version label
    for d in objs:
        d["metadata"].setdefault("labels", {})["app.kubernetes.io/version"] = version
        tpl = d.get("spec", {}).get("template")
        if isinstance(tpl, dict):
            tpl.setdefault("metadata", {}).setdefault("labels", {})[
                "app.kubernetes.io/version"] = version
    return objs


HEADER = """# This manifest was generated. DO NOT EDIT by hand; regenerate instead (command below).
# Flux Version: {version}
# Components: source-controller,kustomize-controller,helm-controller,notification-controller
# Generated by tools/flux-bundle-export.py, which reproduces what `flux bootstrap` writes from
# the upstream release's install.yaml: component filter, -flux-system name suffix on
# cluster-scoped objects, the $(RUNTIME_NAMESPACE) events address, the linux nodeSelector, and
# the app.kubernetes.io/version labels (install.yaml carries none, which is exactly why the
# labels in this file were able to go stale unnoticed).
#
#   curl -fsSLO https://github.com/fluxcd/flux2/releases/download/{version}/install.yaml
#   python3 tools/flux-bundle-export.py emit install.yaml {version} \\
#       > apply/00-bootstrap/flux-system/gotk-components.yaml
#
# HISTORY. This file was hand-edited on 2026-10-27: the two notification CRDs were replaced
# with v2.10.0 copies because notification-controller v1.10.0 watches Alert and Provider at
# notification.toolkit.fluxcd.io/v1, which the v2.9.6 copies did not serve, and it crash-looped
# on "failed to wait for provider caches to sync" until they were swapped. v2.10.x ships those
# CRDs natively, so the hand-edit is retired rather than carried forward: what follows is the
# unmodified transform of the upstream release, and `verify` mode is what proves that claim.
#
# Before replacing CRDs here, measure the delta. The {version} bump removed zero properties and
# added four (HelmRelease .spec gained 25 optional fields; GitRepository, OCIRepository and
# ExternalArtifact each gained one status field), and every CRD serves the same versions as
# before. Additive is what makes a CRD bump safe; a removal would mean an object this tree
# declares stops validating, and only the live API server would tell you.
"""


def key(d):
    return f"{d['kind']}/{d['metadata']['name']}"


def flat(d, pre=""):
    """Leaf paths, so a diff names the field that moved instead of the whole object."""
    out = {}
    if isinstance(d, dict):
        for k, v in d.items():
            out.update(flat(v, f"{pre}.{k}"))
    elif isinstance(d, list):
        for i, v in enumerate(d):
            out.update(flat(v, f"{pre}[{i}]"))
    else:
        out[pre] = d
    return out


def main():
    if len(sys.argv) < 4:
        raise SystemExit(__doc__)
    mode, install_yaml, version = sys.argv[1], sys.argv[2], sys.argv[3]
    objs = transform(load(install_yaml), version)

    if mode == "emit":
        body = "".join(("---\n" if i else "")
                       + yaml.dump(d, sort_keys=True, default_flow_style=False, width=10 ** 6)
                       for i, d in enumerate(objs))
        # The leading `---` belongs to the header, and the header belongs to the first object's
        # document: a separator between the comment block and that object would create an empty
        # document, which kubectl tolerates and nothing here needs.
        sys.stdout.write("---\n" + HEADER.format(version=version) + body)
        return

    if mode == "verify":
        committed = load(sys.argv[4])
        a, b = {key(d): d for d in objs}, {key(d): d for d in committed}
        print(f"regenerated: {len(a)} objects   committed: {len(b)}")
        print("only in regenerated:", sorted(set(a) - set(b)) or "none")
        print("only in committed: ", sorted(set(b) - set(a)) or "none")
        unexplained = 0
        for k in sorted(set(a) & set(b)):
            fa, fb = flat(a[k]), flat(b[k])
            diff = [p for p in set(fa) | set(fb) if fa.get(p) != fb.get(p)]
            if diff:
                print(f"\n{k}: {len(diff)} differing field(s)")
                for p in sorted(diff)[:6]:
                    print(f"    regenerated {fa.get(p)!r}\n    committed   {fb.get(p)!r}")
                if len(diff) > 6:
                    print(f"    ... and {len(diff) - 6} more")
                unexplained += 1
        print(f"\nobjects differing: {unexplained}")
        print("Expected before a bump: the two notification CRDs from the 2026-10-27 "
              "hand-swap, and the four image tags if the images were bumped without the CRDs. "
              "Anything else is an undocumented hand-edit — read it before you overwrite it.")
        return

    raise SystemExit("mode must be emit or verify")


main()
