#!/usr/bin/env python3
"""Assert every Secret a hand-written workload names actually exists in this tree.

Reads multi-document YAML on stdin - the concatenated `kubectl kustomize` output for every
stage directory, each build terminated by an explicit `---`, the same stream crd-check and
namespace-check consume. Built objects, not source files, so a name that only exists after a
kustomize transform is still checked.

WHY THIS EXISTS. `make release-secrets` walks `HelmRelease` objects and nothing else - its
own output line says so ("9 HelmRelease(s), 1 Secret reference(s) scanned") - and
`make secrets-placement` proves three things about a Secret file (it is inside
`apply/10-secrets`, it carries `ENC[`, it is listed in that directory's kustomization) and
nothing about who consumes it. So the Secret references of every hand-written Deployment in
this repo were, until now, checked by nobody. A typo'd name builds green, passes crd-check
(a Secret name is a perfectly legal string), passes namespace-check (the namespace is fine),
and produces a pod stuck in `CreateContainerConfigError` naming a Secret that plainly does
not exist. That is the exact failure PR #162 had to reason about for a different reason -
re-encrypting the investing agent's Secret because techdelivery's ciphertext was unreadable
to titan's kustomize-controller, which produces "a Pending pod naming a Secret that plainly
exists" - and reviewing that PR is what made the gap visible. The name was checked by hand
there. It should not have to be.

WHAT IT CHECKS. For every workload object in the build (Deployment, StatefulSet, DaemonSet,
CronJob, Job), every Secret it names:

  * containers[].envFrom[].secretRef.name
  * containers[].env[].valueFrom.secretKeyRef.name
  * volumes[].secret.secretName and volumes[].projected.sources[].secret.name
  * imagePullSecrets[].name

must be either (a) declared as a `Secret` in the same namespace by this tree, or (b) listed
in PRODUCED_IN_CLUSTER below with a reason. `optional: true` is not an exemption: an optional
reference to a Secret that does not exist is the silent-feature-off failure, not a pass.

VACUITY. It refuses to report clean when it found nothing to check - no workload objects, no
Secret references, or no declared Secrets. A gate that passes on an empty set is worse than
no gate, and the Makefile recipe fails the same way release-secrets does.

A MALFORMED STREAM IS THE TOOL'S OWN FAILURE MODE, so it is named here rather than left as a
footnote. Every stage build has to be terminated by an explicit `---` (the Makefile recipe
does this; namespace-check's docstring says why). While this tool was being written an ad-hoc
build loop omitted that separator, `sure/sure-secrets` merged into the next stage's first
object and stopped existing as a Secret, and the gate failed on `Deployment sure/sure-redis`
instead of reporting clean. Be clear about what that proves: which object survives a merge
depends on which key wins, so a lost Secret is a loud false red and a lost workload is a
silent gap. There is no cheap invariant that catches a mid-stream merge - dropping one
separator removes a document and a separator together, so document counts stay consistent -
which is why the separator belongs to the one recipe that all three built-object gates share,
and why the success line prints the workload count for a human to sanity-check.

WHAT IT DOES NOT PROVE, and this is the honest limit, the same one release-secrets states:
it proves a name and a namespace exist in the tree, not that the keys inside are what the
application wants. `envFrom` on a Secret with the wrong key names resolves cleanly and ships
an app with no configuration. Nor can it see a Secret that exists live but is not declared
here - that is what PRODUCED_IN_CLUSTER is for, and every entry in it is a deliberate hole
with a named producer, not an oversight.
"""
import sys

import yaml

WORKLOAD_KINDS = frozenset({"CronJob", "DaemonSet", "Deployment", "Job", "StatefulSet"})

# Secrets a workload legitimately names that this repo does not declare, because something
# running in the cluster creates them. Each entry is (namespace, name) and the reason it is
# here. An entry is a hole in the gate: if the producer ever stops making the Secret, nothing
# here notices, so nothing belongs on this list that has not been earned.
#
# One entry, and it stayed at one while writing this. `postgres-exporter-credentials` looked
# like a second candidate - CloudNativePG does create it for the monitoring role - but the
# repo declares it in apply/10-secrets/postgres-exporter-secrets.yaml anyway, so it resolves
# normally and does not get to be a hole.
PRODUCED_IN_CLUSTER = {
    # Produced by the wildcard Certificate in apply/40-certificates/titan-wildcard.yaml and
    # copied into `apps` by Reflector. tesla-fleet-telemetry mounts it as a client certificate,
    # so here a workload consumes it rather than the usual consumer, an Ingress.
    ("apps", "titan-tls"): "cert-manager Certificate, reflected into apps by Reflector",
}


def secret_refs(doc):
    """Yield (namespace, secret_name, where) for every Secret a workload object names."""
    kind = doc["kind"]
    ns = (doc.get("metadata") or {}).get("namespace") or "<no-namespace>"
    name = (doc.get("metadata") or {}).get("name") or "<unnamed>"
    where = f"{kind} {ns}/{name}"

    if kind == "CronJob":
        spec = (((doc.get("spec") or {}).get("jobTemplate") or {}).get("spec") or {}).get("template", {}).get("spec")
    else:
        spec = ((doc.get("spec") or {}).get("template") or {}).get("spec")
    if not isinstance(spec, dict):
        return

    for pull in spec.get("imagePullSecrets") or []:
        if isinstance(pull, dict) and pull.get("name"):
            yield ns, pull["name"], f"{where} imagePullSecrets"

    for container_key in ("containers", "initContainers", "ephemeralContainers"):
        for container in spec.get(container_key) or []:
            if not isinstance(container, dict):
                continue
            for entry in container.get("envFrom") or []:
                if not isinstance(entry, dict):
                    continue
                ref = entry.get("secretRef")
                if isinstance(ref, dict) and ref.get("name"):
                    yield ns, ref["name"], f"{where} envFrom"
            for env in container.get("env") or []:
                if not isinstance(env, dict):
                    continue
                value_from = env.get("valueFrom") or {}
                ref = value_from.get("secretKeyRef") if isinstance(value_from, dict) else None
                if isinstance(ref, dict) and ref.get("name"):
                    yield ns, ref["name"], f"{where} env {env.get('name')}"
    for volume in spec.get("volumes") or []:
        if not isinstance(volume, dict):
            continue
        secret = volume.get("secret")
        if isinstance(secret, dict) and secret.get("secretName"):
            yield ns, secret["secretName"], f"{where} volume {volume.get('name')}"
        projected = volume.get("projected")
        if isinstance(projected, dict):
            for source in projected.get("sources") or []:
                if isinstance(source, dict) and isinstance(source.get("secret"), dict):
                    if source["secret"].get("name"):
                        yield ns, source["secret"]["name"], f"{where} projected volume {volume.get('name')}"


def main():
    try:
        docs = [doc for doc in yaml.safe_load_all(sys.stdin) if doc]
    except yaml.YAMLError as exc:
        print(f"FAIL: stdin is not parseable YAML: {exc}")
        return 1

    declared = set()
    for doc in docs:
        if doc.get("kind") == "Secret":
            meta = doc.get("metadata") or {}
            declared.add((meta.get("namespace") or "<no-namespace>", meta.get("name") or "<unnamed>"))

    workloads = [doc for doc in docs if doc.get("kind") in WORKLOAD_KINDS]
    if not workloads:
        print("FAIL: no workload object in the build - secret-refs cannot pass vacuously")
        return 1
    if not declared:
        print("FAIL: no Secret declared in the build - secret-refs cannot pass vacuously")
        return 1

    refs = list(ref for doc in workloads for ref in secret_refs(doc))
    if not refs:
        print("FAIL: no workload in the build names a Secret - the scanner found nothing to check")
        return 1

    missing = []
    allow_used = set()
    for ns, secret_name, where in refs:
        key = (ns, secret_name)
        if key in declared:
            continue
        if key in PRODUCED_IN_CLUSTER:
            allow_used.add(key)
            continue
        missing.append((ns, secret_name, where))

    if missing:
        print("FAIL: a workload references a Secret this tree does not declare:")
        for ns, secret_name, where in missing:
            print(f"  {ns}/{secret_name}  <- {where}")
            print(f"      either declare it under apply/10-secrets in namespace {ns}, or, if the")
            print("      cluster produces it, add it to PRODUCED_IN_CLUSTER in tools/secret-refs-check.py")
        return 1

    allow = len(allow_used)
    print(
        f"secret-refs: {len(workloads)} workload object(s), {len(refs)} Secret reference(s) scanned; "
        f"{len(refs) - allow} resolved against declared Secrets, {allow} allow-listed as produced in-cluster"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
