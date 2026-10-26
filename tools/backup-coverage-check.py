#!/usr/bin/env python3
"""backup-coverage: every PVC that opted in is actually reachable by a backup runner.

Reads multi-document YAML on stdin - the concatenated `kubectl kustomize` output for every stage
directory, each build terminated by an explicit `---`, the same stream crd-check, namespace-check
and secret-refs consume. Built objects, not source files.

WHY THIS EXISTS. The backup stage stopped enumerating volumes and started discovering them: a PVC
opts in with `backup.titan.arrieta.eu/class`, and a per-namespace runner finds it at runtime. That
is what makes a coder workspace volume backuppable at all - its name is a UUID that changes when
the workspace is rebuilt, so no static manifest could name it - but it moves the scope decision
into an annotation, and an annotation only works if four separate things in three files agree:

  * the PVC carries the annotation;
  * that namespace has a `backup-discovery` CronJob, because a runner only sees PVCs in its own
    namespace and a PVC in an unrunnered namespace is silently never backed up;
  * that namespace is in the reflector-auto-namespaces list on BOTH backup-minio-secrets and
    backup-preflight, because the child job mounts a ConfigMap and reads a Secret that Reflector
    mirrors, and a child job whose namespace was forgotten lands in CreateContainerConfigError;
  * that namespace has the runner's ServiceAccount, Role and RoleBinding, which nothing can
    mirror because RBAC is namespace-local.

Every one of those four is a one-line edit in a different file, and every one of them fails the
same way: quietly, at 18:30 the next night, in a namespace nobody is looking at. `secret-refs`
cannot cover the third bullet - the jobs that reference the mirrored Secret are created at runtime
by the runner and are not in the tree, so the gate sees only the housekeeping jobs in `apps` and
is right to pass. That blind spot is this gate's reason for existing.

VACUITY. Refuses to report clean when it found no annotated PVCs or no runners. A tree where the
annotation was renamed, or where the backup stage was deleted, would otherwise pass by inspecting
nothing - the failure mode this repo has already been bitten by twice.

WHAT IT DOES NOT PROVE, and the honest limit is wide here. It proves the wiring agrees in the tree.
It cannot prove the annotation is on the live PVCs (coder's volumes are created at runtime and are
annotated by coder-templates, in another repo), that Reflector is healthy, that the credential
inside the mirrored Secret is the right one, or that a backup ever ran. The first two need a live
cluster and belong beside `make dry-run`, which needs an admin context; the last needs the restore
drill the spec says has not happened.
"""
import sys

import yaml

ANNOTATION = "backup.titan.arrieta.eu/class"
AUTO_NS = "reflector.v1.k8s.emberstack.com/reflection-auto-namespaces"
# Classes the runner knows how to schedule. A class outside this set is not a schedule the
# operator chose; it is a typo that the runner would happily treat as "some non-empty string" and
# back up with the default policy, which is a silent wrong answer rather than a loud one.
KNOWN_CLASSES = {"daily"}
SOURCE_NAMESPACE = "apps"


def fail(problems, msg):
    problems.append(msg)


def main():
    try:
        docs = [d for d in yaml.safe_load_all(sys.stdin) if d]
    except yaml.YAMLError as exc:
        sys.exit(f"backup-coverage: cannot parse the built stream - {exc}")

    problems = []
    annotated = {}       # namespace -> [pvc names]
    runners = set()
    mirrored = {}        # object name -> set(namespaces) from its reflector annotation
    identities = {}      # namespace -> set of kinds present for the runner identity

    for doc in docs:
        kind = doc.get("kind")
        meta = doc.get("metadata") or {}
        ns = meta.get("namespace") or "<no-namespace>"
        name = meta.get("name") or "<unnamed>"

        if kind == "PersistentVolumeClaim":
            cls = ((meta.get("annotations") or {}).get(ANNOTATION) or "").strip()
            if cls and cls != "none":
                annotated.setdefault(ns, []).append(name)
                if cls not in KNOWN_CLASSES:
                    fail(problems, f"PVC {ns}/{name} carries class '{cls}', which no runner "
                                   f"schedules (known: {', '.join(sorted(KNOWN_CLASSES))})")

        elif kind == "CronJob" and name == "backup-discovery":
            runners.add(ns)

        elif kind in ("Secret", "ConfigMap") and name in ("backup-minio-secrets", "backup-preflight"):
            raw = ((meta.get("annotations") or {}).get(AUTO_NS) or "").strip()
            mirrored[name] = {n.strip() for n in raw.split(",") if n.strip()}

        elif kind in ("ServiceAccount", "Role", "RoleBinding") and name == "backup-runner":
            identities.setdefault(ns, set()).add(kind)

    if not annotated:
        sys.exit(f"backup-coverage: no PVC carries {ANNOTATION} - refusing to report clean. "
                 "Either nothing has opted in yet or the annotation was renamed; a gate that "
                 "inspects an empty set is worse than no gate.")
    if not runners:
        sys.exit("backup-coverage: no backup-discovery CronJob found - refusing to report clean.")
    if len(mirrored) < 2:
        sys.exit("backup-coverage: expected both backup-minio-secrets and backup-preflight to "
                 f"carry {AUTO_NS}; found {sorted(mirrored) or 'neither'}. Refusing to report "
                 "clean: the child jobs need both objects in their namespace.")

    # The two mirror lists are one decision written twice, which is this repo's favourite shape of
    # bug. They are compared rather than trusted.
    lists = list(mirrored.items())
    if lists[0][1] != lists[1][1]:
        fail(problems, f"the reflector mirror lists disagree: {lists[0][0]} covers "
                       f"{sorted(lists[0][1])} but {lists[1][0]} covers {sorted(lists[1][1])}. "
                       "A child job needs both objects present, so a namespace in only one is a "
                       "CreateContainerConfigError waiting for the night it runs.")
    mirrored_ns = set().union(*[set(v) for v in mirrored.values()]) | {SOURCE_NAMESPACE}

    for ns, pvcs in sorted(annotated.items()):
        if ns not in runners:
            fail(problems, f"{ns}: PVC(s) {pvcs} opted in but no backup-discovery CronJob runs "
                           "there, so nothing will ever find them")
        if ns not in mirrored_ns:
            fail(problems, f"{ns}: PVC(s) {pvcs} opted in but the namespace is not mirrored, so "
                           "the child job's Secret and ConfigMap will not exist there")

    for ns in sorted(runners):
        if ns not in mirrored_ns:
            fail(problems, f"{ns}: has a runner but is not mirrored, so its child jobs cannot "
                           "mount the scripts or read the credential")
        missing = {"ServiceAccount", "Role", "RoleBinding"} - identities.get(ns, set())
        if missing:
            fail(problems, f"{ns}: runner exists but {sorted(missing)} is missing, so the pod "
                           "cannot list PVCs or create jobs")

    if problems:
        print(f"backup-coverage: {len(problems)} problem(s)")
        for p in problems:
            print(f"  FAIL: {p}")
        sys.exit(1)

    total = sum(len(v) for v in annotated.values())
    print(f"backup-coverage: {total} opted-in PVC(s) across {len(annotated)} namespace(s); "
          f"{len(runners)} runner(s), {len(mirrored_ns)} mirrored namespace(s), every runner "
          "has its identity and its mirrors")


if __name__ == "__main__":
    main()
