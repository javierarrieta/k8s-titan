#!/usr/bin/env python3
"""blueprint-mount-check: an authentik blueprint that is written, valid, applied to the cluster,
and never read by the worker is indistinguishable from one that was never written.

docs/authentik-runbook.md §5 is the record of that costing an hour of live breakage on
2026-10-20, and of a second blueprint being skipped by the very discovery pass that should have
caught it. Every one of those failures was green in every gate this repo had, because no gate
asked whether the mount existed. This does, in four directions:

  1. EXISTS BUT UNMOUNTED - a ConfigMap in the HelmRelease's namespace carrying a real blueprint
     (a `.yaml` key whose value parses to a mapping with `version` and `entries`) that is not
     listed under `blueprints.configMaps`. This is the 2026-10-20 shape.
     For Secrets the same check runs on the name convention (`authentik-*-blueprint`) instead of
     on content, because a sops ciphertext is not parseable YAML and this gate is keyless by
     design - see the honest limits at the bottom.
  2. MOUNTED BUT MISSING - a name in `blueprints.configMaps` / `blueprints.secrets` with no such
     object in the HelmRelease's own namespace. The chart mounts these by name, so a typo leaves
     the pod Pending, which reads as a chart bug.
  3. MOUNTED BUT NOT RELOAD-WIRED - kubelet rewrites a mounted Secret/ConfigMap in place and the
     worker only discovers blueprints at startup plus on a beat pass measured at up to ~50 minute
     gaps, so a name that is mounted but absent from the worker's reloader annotation edits
     silently up to an hour late and looks like it did not land.
  4. NEVER PASSES VACUOUSLY - no authentik HelmRelease, no `blueprints` block, or a `blueprints`
     block this script cannot read is a failure, not a clean run.

Honest limits, stated because a gate that overstates itself gets trusted too much:
  * It proves a name is mounted and reload-wired. It does NOT prove the worker applied it, or that
    it applied cleanly - that is `ak apply_blueprint` and the worker log, runbook §5.
  * It reads Secret NAMES only, never Secret content, so it cannot tell whether a mounted Secret
    actually holds a blueprint, nor whether the blueprint inside it is valid.
  * It reads the pinned chart's `blueprints.configMaps` / `blueprints.secrets` shape only. Any
    other key under `blueprints` fails rather than being skipped quietly.

Usage: kubectl kustomize <dirs> | blueprint-mount-check.py
"""

import sys
import yaml

CHART = "authentik"
# The chart's own two mount lists (chart authentik-2026.8.5, values.yaml:220-226). Anything else
# under `blueprints` is a shape this script has not read and must not pretend to have checked.
MOUNT_KEYS = ("configMaps", "secrets")
KIND_FOR_KEY = {"configMaps": "ConfigMap", "secrets": "Secret"}
RELOADER_FOR_KEY = {
    "configMaps": "configmap.reloader.stakater.com/reload",
    "secrets": "secret.reloader.stakater.com/reload",
}
# Secret blueprints are detected by this prefix because their content is sops ciphertext.
SECRET_PREFIX = "authentik-"
SECRET_SUFFIX = "-blueprint"


class TagTolerantLoader(yaml.SafeLoader):
    """Blueprint YAML carries authentik's own tags (!KeyOf, !Find, !Context, !Format). A strict
    loader raises on them, which would make every real blueprint look like a non-blueprint and
    silently empty this gate - the vacuous-pass failure mode this file exists to prevent."""


TagTolerantLoader.add_multi_constructor("!", lambda loader, suffix, node: None)


def is_blueprint_value(value):
    """True if a ConfigMap data value is an authentik blueprint: a mapping with the two keys
    every blueprint has and few other objects use together."""
    if not isinstance(value, str):
        return False
    try:
        parsed = yaml.load(value, Loader=TagTolerantLoader)
    except yaml.YAMLError:
        return False
    return isinstance(parsed, dict) and "version" in parsed and "entries" in parsed


def main():
    docs = []
    for doc in yaml.load_all(sys.stdin, Loader=TagTolerantLoader):
        if isinstance(doc, dict) and doc.get("kind"):
            docs.append(doc)

    releases = [
        d
        for d in docs
        if d.get("kind") == "HelmRelease"
        and ((d.get("spec") or {}).get("chart") or {}).get("spec", {}).get("chart") == CHART
    ]
    if not releases:
        print(
            f"FAIL: no {CHART} HelmRelease found in the built tree - blueprint-mount-check "
            "cannot pass vacuously"
        )
        return 1

    # Objects by (kind, namespace, name), plus which ConfigMaps actually carry a blueprint.
    present = set()
    blueprint_cms = set()
    secret_named_blueprints = set()
    for d in docs:
        kind = d.get("kind")
        if kind not in ("ConfigMap", "Secret"):
            continue
        meta = d.get("metadata") or {}
        ns, name = meta.get("namespace"), meta.get("name")
        if not ns or not name:
            continue
        present.add((kind, ns, name))
        if kind == "ConfigMap":
            data = d.get("data") or {}
            if any(k.endswith(".yaml") and is_blueprint_value(v) for k, v in data.items()):
                blueprint_cms.add((ns, name))
        elif name.startswith(SECRET_PREFIX) and name.endswith(SECRET_SUFFIX):
            secret_named_blueprints.add((ns, name))

    failures = []
    checked_mounts = 0
    for hr in releases:
        ns = (hr.get("metadata") or {}).get("namespace")
        name = (hr.get("metadata") or {}).get("name")
        values = (hr.get("spec") or {}).get("values") or {}
        blueprints = values.get("blueprints")
        if not isinstance(blueprints, dict):
            failures.append(
                f"{ns}/{name}: no `blueprints` block in values - every blueprint this repo "
                "declares would be silently unmounted"
            )
            continue
        unknown = sorted(set(blueprints) - set(MOUNT_KEYS))
        if unknown:
            failures.append(
                f"{ns}/{name}: `blueprints` carries key(s) this gate cannot read: "
                f"{', '.join(unknown)} - read tools/blueprint-mount-check.py and extend it"
            )

        # The worker is the only component that applies blueprints; the server does not, so
        # wiring a mount to the server alone is the same bug as not wiring it at all.
        worker = values.get("worker") or {}
        worker_ann = (worker.get("podAnnotations") or {}) if isinstance(worker, dict) else {}
        auto = str(worker_ann.get("reloader.stakater.com/auto", "")).lower() == "true"
        reload_lists = {}
        for key in MOUNT_KEYS:
            raw = worker_ann.get(RELOADER_FOR_KEY[key], "")
            reload_lists[key] = {part.strip() for part in str(raw).split(",") if part.strip()}

        for key in MOUNT_KEYS:
            listed = blueprints.get(key)
            if listed is None:
                listed = []
            if not isinstance(listed, list):
                failures.append(
                    f"{ns}/{name}: `blueprints.{key}` is not a list - cannot be scanned"
                )
                continue
            kind = KIND_FOR_KEY[key]
            for mount in listed:
                checked_mounts += 1
                if not isinstance(mount, str) or not mount:
                    failures.append(f"{ns}/{name}: `blueprints.{key}` has a non-string entry")
                    continue
                if (kind, ns, mount) not in present:
                    failures.append(
                        f"{ns}/{name}: `blueprints.{key}` mounts {mount!r} but no {kind} "
                        f"{ns}/{mount} exists in this tree"
                    )
                if not auto and mount not in reload_lists[key]:
                    failures.append(
                        f"{ns}/{name}: {mount!r} is mounted but not in the worker's "
                        f"{RELOADER_FOR_KEY[key]} annotation, so an edit lands up to an hour "
                        "late and reads as a no-op (runbook §5)"
                    )

            # Reverse direction: a blueprint object in this namespace that the release never
            # mounts. Secrets are matched on the name convention, ConfigMaps on content.
            pool = (
                blueprint_cms if key == "configMaps" else secret_named_blueprints
            )
            for (cns, cname) in sorted(pool):
                if cns != ns:
                    continue
                if cname not in {m for m in (blueprints.get(key) or []) if isinstance(m, str)}:
                    failures.append(
                        f"{ns}/{name}: {KIND_FOR_KEY[key]} {cns}/{cname} carries a blueprint but "
                        f"is not listed under `blueprints.{key}` - it will never be applied"
                    )

    if failures:
        print("FAIL: authentik blueprint mounts:")
        for line in failures:
            print(f"  {line}")
        return 1

    print(
        f"blueprint-mount-check: {len(releases)} authentik HelmRelease(s), "
        f"{checked_mounts} mount(s) scanned; every blueprint in the tree mounted by name and "
        "reload-wired on the worker (Secret content is never read - see the gate's own docstring)"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
