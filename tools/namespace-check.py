#!/usr/bin/env python3
"""Assert every namespace a built object names is a namespace this repo actually declares.

Reads multi-document YAML on stdin - the concatenated `kubectl kustomize` output for every
stage directory, each build terminated by an explicit `---` (see the crd-check recipe; a
merged stream makes objects that do not exist). CRD directories may be given as argv and
are used for one thing only: deciding whether a Kind is namespaced or cluster-scoped.

WHY THIS EXISTS. On 2026-10-21 the apps stage went red for three hours because
grafana-postgres-dashboard carried `namespace: casa` - copied from k8s-casa, where `casa`
is a real namespace. No gate here had anything to say about it. The manifest built, the
CRD field check passed (a namespace is a perfectly legal field), and `make dry-run` - the
only gate that asks the API server - was not run. The server rejects it at apply time with
`namespaces "casa" not found`, and because Flux applies a Kustomization atomically, one bad
namespace stops every other manifest in the stage: no partial apply, and nothing in the
build to hint at it. The dashboard the operator was looking for stayed absent, and so did
the exporter shipped in the same commit.

TWO ASSERTIONS, both provable from the tree alone:

  1. A namespace named by a manifest must be declared by a Namespace object in the same
     tree, or be one the control plane creates. That is the casa bug.

  2. A namespaced object must not omit metadata.namespace. Flux does not default it to the
     stage's own namespace - an omitted namespace lands in `default`, which exists, so
     assertion 1 cannot see it. The object applies cleanly into a namespace nobody meant,
     the pod mounts nothing, and the symptom is a missing panel three hops away.

  3. Policy, not existence: no Flux Kustomization may set spec.targetNamespace, and no
     HelmRelease may name a targetNamespace the tree does not declare. Both rewrite where
     objects land, which is the same failure class as a wrong metadata.namespace. AGENTS.md
     already forbids the kustomize.yaml equivalent ("never set a top-level namespace: these
     trees span several namespaces and that field rewrites them all"); this is the Flux-side
     half of that rule.

WHAT IT DOES NOT PROVE, and this is the honest limit: that the namespace is the RIGHT one.
`namespace: apps` on a Grafana dashboard passes - the namespace exists. Existence, not
intent. It also cannot see a namespace that exists live but is not declared here; that is
deliberate. Every namespace this cluster uses is declared in this tree, which is what makes
the check decidable offline; a namespace created out of band would need a commit, and that
is the point rather than an obstacle.
"""
import sys

import yaml

# Created by the control plane, never by this repo. None of them are used by a manifest
# today; the list exists so the gate does not invent work if one is ever needed, and so
# `default` is named explicitly rather than arrived at by omission (assertion 2 rejects
# the omission).
CLUSTER_PROVIDED = frozenset({"default", "kube-system", "kube-public", "kube-node-lease"})

# Built-in kinds that carry no namespace. A namespaced object that omits metadata.namespace
# must be distinguishable from these, or the gate would fire on every ClusterRole in the
# tree. CustomResourceDefinitions seen in this build: 22. ClusterRole: 10.
# ClusterRoleBinding: 8. StorageClass: 1. That is the whole unset set as of this writing.
#
# ClusterIssuer and ClusterReceiver are CRs, not built-ins, and their CRDs are not vendored
# here - ClusterIssuer is referenced by every Certificate in this repo. They are listed so
# that promoting one from reference to object does not produce a false positive.
CLUSTER_SCOPED_KINDS = frozenset({
    "APIService",
    "ClusterIssuer",
    "ClusterReceiver",
    "ClusterRole",
    "ClusterRoleBinding",
    "CSIDriver",
    "CSINode",
    "CustomResourceDefinition",
    "IngressClass",
    "MutatingWebhookConfiguration",
    "Namespace",
    "Node",
    "PersistentVolume",
    "PriorityClass",
    "StorageClass",
    "ValidatingWebhookConfiguration",
    "VolumeAttachment",
})

# Where a HelmRelease may say which namespace its resources land in.
HELM_TARGET_PATHS = (
    ("install", "spec", "targetNamespace"),
    ("upgrade", "spec", "targetNamespace"),
    ("test", "spec", "targetNamespace"),
    ("rollback", "spec", "targetNamespace"),
)


def crd_scopes(directories):
    """Kind -> 'Cluster' for every cluster-scoped CRD found, so CRs are not guessed at."""
    import glob
    import os

    cluster_scoped = set()
    for directory in directories:
        for path in sorted(glob.glob(os.path.join(directory, "*.yaml"))):
            with open(path) as handle:
                for doc in yaml.safe_load_all(handle):
                    if not doc or doc.get("kind") != "CustomResourceDefinition":
                        continue
                    if doc.get("spec", {}).get("scope") == "Cluster":
                        cluster_scoped.add(doc["spec"]["names"]["kind"])
    return cluster_scoped


def dig(obj, path):
    node = obj
    for key in path:
        if not isinstance(node, dict):
            return None
        node = node.get(key)
    return node


def main():
    crd_dirs = sys.argv[1:]
    try:
        docs = [doc for doc in yaml.safe_load_all(sys.stdin) if doc]
    except yaml.YAMLError as exc:
        print(f"namespace-check: stdin is not parseable YAML ({exc}) - refusing to report clean")
        return 2

    if not docs:
        print("namespace-check: 0 objects on stdin - refusing to report clean")
        return 2

    declared = {d["metadata"]["name"] for d in docs
                if d.get("kind") == "Namespace" and d.get("metadata", {}).get("name")}
    if not declared:
        print("namespace-check: the build declared no Namespace object at all - refusing to "
              "report clean (an empty allow-list would make every object look wrong, or, if "
              "nothing is namespaced, look vacuously right)")
        return 2

    cluster_scoped = CLUSTER_SCOPED_KINDS | crd_scopes(crd_dirs)
    allowed = declared | CLUSTER_PROVIDED

    failures = []
    checked = 0
    referenced = set()
    for obj in docs:
        kind = obj.get("kind")
        name = obj.get("metadata", {}).get("name")
        if not kind or not name:
            failures.append(f"<{kind or 'no kind'}/{name or 'no name'}>: object without kind or name")
            continue

        if kind == "Namespace":
            continue

        if kind == "Kustomization" and dig(obj, ("spec", "targetNamespace")):
            failures.append(f"Kustomization/{name}: sets spec.targetNamespace="
                            f"{dig(obj, ('spec', 'targetNamespace'))!r} - it rewrites where every "
                            "object in the stage lands, which AGENTS.md forbids for the "
                            "kustomize.yaml equivalent for the same reason")
        if kind == "HelmRelease":
            for path in HELM_TARGET_PATHS:
                target = dig(obj, ("spec",) + path)
                if target and target not in allowed:
                    failures.append(f"HelmRelease/{name}: {'.'.join(path)}={target!r} is not "
                                    "declared by a Namespace object in this tree")

        namespace = obj.get("metadata", {}).get("namespace")
        if namespace:
            checked += 1
            referenced.add(namespace)
            if namespace not in allowed:
                failures.append(f"{kind}/{name}: namespace={namespace!r} is not declared by any "
                                f"Namespace object in this tree (the API server answers "
                                f"'namespaces \"{namespace}\" not found' and the whole stage is "
                                f"blocked, because Flux applies a stage atomically)")
        elif kind not in cluster_scoped:
            checked += 1
            failures.append(f"{kind}/{name}: no metadata.namespace, so it lands in 'default' - "
                            "which exists, so nothing else will ever complain about it")

    if checked == 0:
        print("namespace-check: 0 namespaced objects checked - refusing to report clean")
        return 2
    if failures:
        print("FAIL: namespace declared by a manifest that the tree does not declare, or a "
              "namespaced object with no namespace at all:")
        for failure in failures:
            print(f"  {failure}")
        return 1
    print(f"namespace-check: {checked} object(s) checked; {len(referenced)} namespace(s) "
          f"referenced ({', '.join(sorted(referenced))}), every one declared by the tree "
          f"({len(declared)} Namespace object(s)) or created by the control plane")
    return 0


if __name__ == "__main__":
    sys.exit(main())
