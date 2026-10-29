#!/usr/bin/env python3
"""blueprint-mount-check: an authentik blueprint that is written, valid, applied to the cluster,
and never read by the worker is indistinguishable from one that was never written.

docs/authentik-runbook.md §5 is the record of that costing an hour of live breakage on
2026-10-20, and of a second blueprint being skipped by the very discovery pass that should have
caught it. Every one of those failures was green in every gate this repo had, because no gate
asked whether the mount existed. This does, in six directions:

  1. EXISTS BUT UNMOUNTED - a ConfigMap anywhere in the tree carrying a real blueprint (a `.yaml`
     key whose value parses to a mapping with `entries`) that no authentik release lists under
     `blueprints.configMaps`. This is the 2026-10-20 shape.
     Tree-wide rather than release-scoped on purpose: the chart mounts by name inside the release's
     OWN namespace only (chart authentik-2026.8.5, templates/worker/deployment.yaml:102-109), so a
     blueprint ConfigMap committed into the wrong namespace is mounted by nothing, applies nothing,
     and reads exactly like a blueprint that was never written. namespace-check exists because a
     wrong namespace once held this repo's whole `apps` stage red for three hours; this is the same
     class of error one object type further on.
     For Secrets the same check runs on the name convention (`authentik-*-blueprint`) instead of
     on content, because a sops ciphertext is not parseable YAML and this gate is keyless by
     design - see the honest limits at the bottom.
  2. MOUNTED BUT MISSING - a name in `blueprints.configMaps` / `blueprints.secrets` with no such
     object in the HelmRelease's own namespace. The chart mounts these by name, so a typo leaves
     the pod Pending, which reads as a chart bug.
  2b. MOUNTED BUT NOT DISCOVERABLE - a ConfigMap that is mounted, and reload-wired, but that the
     worker will never read. Three ways, all from authentik's own discovery pass
     (authentik/blueprints/v1/tasks.py:126-143): no key ending in `.yaml` at all (the discovery
     glob is `rglob("**/*.yaml")`), or no `.yaml` key whose body parses to a mapping with
     `entries`, or a `version` that is not 1 - authentik warns and skips those
     (tasks.py:141-143). So `identity.yml`, a body with no `entries`, and `version: 2` each mount
     cleanly, satisfy every other check here, and are never applied. Found by review of PR #194:
     renaming the key was enough to make the gate report clean.
     Note `entries` alone is the blueprint signal, deliberately. Requiring `version` as well - the
     first draft of this gate - rejects a blueprint authentik applies happily, because a missing
     `version` defaults to 1 (tasks.py:140). A gate that fails a correct tree gets worked around.
  3. MOUNTED BUT NOT RELOAD-WIRED - kubelet rewrites a mounted Secret/ConfigMap in place and the
     worker only discovers blueprints at startup plus on a beat pass measured at up to ~50 minute
     gaps, so a name that is mounted but absent from the worker's reloader annotation edits
     silently up to an hour late and looks like it did not land.
  3b. RELOAD-WIRED BUT GONE - the other direction, because the two lists are the thing that drifts:
     a name left in the worker's reloader annotation with no object behind it any more is a dead
     entry that proves nothing. Only names with no object at all are flagged; a name that exists but
     is not a blueprint mount is legitimate (`authentik-secrets` is in the worker's Secret
     annotation for envFrom, not for blueprints).
  4. BINDING NAMES A GROUP THAT IS NOT DECLARED - a `authentik_policies.policybinding` whose `group`
     resolves (via `!Find [authentik_core.group, [name, X]]`) to a name no blueprint in this tree
     declares. This is the same class of error as `release-secrets` and `secret-refs`, one object type
     further on, and it is worse than a typo in a role expression: a binding naming a group that does
     not exist DENIES rather than allows, so the app it is bound to silently stops admitting people -
     including, if it is the only binding, the person who wrote it. Found by reading the bindings
     added in PR #198 and asking what would have happened if the group name had been misspelled.
  5. NEVER PASSES VACUOUSLY - no authentik HelmRelease, no `blueprints` block, or a `blueprints`
     block this script cannot read is a failure, not a clean run. So is a missing template directory,
     or templates that exist but yield no binding at all: either the templates moved, this scanner
     broke, or every binding was removed - and a gate that silently scans nothing is the failure mode
     this file exists to prevent.

Honest limits, stated because a gate that overstates itself gets trusted too much:
  * It proves a name is mounted, reload-wired, and carries a parseable blueprint body under a `.yaml`
    key at version 1. It does NOT prove the worker applied it, or that it applied cleanly - that is
    `ak apply_blueprint` and the worker log, runbook §5. It parses the blueprint's shape, never its
    validity against authentik's schema.
  * It reads Secret NAMES only, never Secret content, so it cannot tell whether a mounted Secret
    actually holds a blueprint, nor whether the blueprint inside it is valid. And an
    `authentik-*-blueprint` Secret in some namespace with no authentik release is reported as
    unmounted on its NAME alone, which is a guess about a body this gate cannot read.
  * It reads the pinned chart's `blueprints.configMaps` / `blueprints.secrets` shape only. Any
    other key under `blueprints` fails rather than being skipped quietly.
  * A blueprint body whose key ends in `.yaml` but which is not a mapping (a string, a list) is not
    a blueprint as far as this gate is concerned, and is therefore invisible rather than a failure.
    Authentik skips those too, so the outcome is the same and the shape is not one this repo writes.
  * Group declarations are read from plaintext blueprint bodies only - ConfigMaps in the built tree
    and the `authentik/blueprints-*.yaml` templates. A group declared inside a sops-encrypted
    blueprint Secret is invisible here, and a binding pointing at one would be reported as
    undeclared. Every group this repo declares lives in the plaintext `authentik-identity-blueprint`
    ConfigMap for exactly that reason; a group that must stay secret goes in `DECLARED_ELSEWHERE`
    with a citation, the same shape `secret-refs-check.py` uses for `PRODUCED_IN_CLUSTER`.
  * Bindings are read from the templates, not from the mounted Secrets, because the Secrets are
    ciphertext. So this proves the template is coherent, not that the mounted Secret matches it -
    `scripts/rerender-authentik-blueprint.sh` with no `--write` is the tool that proves that half.
  * A `!Find` on a group by anything other than `name` is reported rather than guessed at, because a
    gate that cannot resolve a reference must say so instead of assuming it resolved.
  * A binding that references a `policy:` or a `user:` instead of a `group:` is out of scope and is
    skipped silently; only group references have a declaration in this tree to check against.

Usage: kubectl kustomize <dirs> | blueprint-mount-check.py
"""

import sys
from pathlib import Path

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
# Authentik's own discovery rules, at the pinned app version 2026.8.5. Cited to the code rather
# than to the chart's values.yaml comment, because comments are what go stale: the chart comment
# and the glob agree today (values.yaml:222 and tasks.py:126 both say `.yaml`).
DISCOVERY_GLOB = "authentik/blueprints/v1/tasks.py:126"
VERSION_RULE = "authentik/blueprints/v1/tasks.py:140-143"
BLUEPRINT_VERSION = 1

# --- group references (check 4) ------------------------------------------------------------------
BINDING_MODEL = "authentik_policies.policybinding"
GROUP_MODEL = "authentik_core.group"
# The plaintext source of every encrypted blueprint Secret. Read from disk, not from stdin, because
# the built tree holds the ciphertext version of these files.
TEMPLATE_GLOB = "authentik/blueprints-*.yaml"
REPO = Path(__file__).resolve().parents[1]
# Groups that legitimately exist without being declared in this tree. An entry here is a deliberate
# gap, not a fix - the same meaning `PRODUCED_IN_CLUSTER` carries in secret-refs-check.py.
# Empty today: every group bound in this repo is a group this repo declares.
DECLARED_ELSEWHERE = frozenset()


class TagTolerantLoader(yaml.SafeLoader):
    """Blueprint YAML carries authentik's own tags (!KeyOf, !Find, !Context, !Format). A strict
    loader raises on them, which would make every real blueprint look like a non-blueprint and
    silently empty this gate - the vacuous-pass failure mode this file exists to prevent."""


TagTolerantLoader.add_multi_constructor("!", lambda loader, suffix, node: None)
# `!Find` is the one tag this gate has to read rather than flatten: a group reference IS a !Find, so
# mapping every tag to None (the previous behaviour) would make each binding look like it referenced
# nothing and pass check 4 by being blind.
TagTolerantLoader.add_constructor(
    "!Find", lambda loader, node: loader.construct_sequence(node)
)


def blueprint_entries(value):
    """The entry list of a blueprint body, or None if this value is not one.

    Accepts a bare blueprint (`entries:` at the top) and a ConfigMap/Secret wrapper whose `data` or
    `stringData` holds one under a `.yaml` key - both shapes appear in this tree.
    """
    if isinstance(value, str):
        try:
            value = yaml.load(value, Loader=TagTolerantLoader)
        except yaml.YAMLError:
            return None
    if not isinstance(value, dict):
        return None
    if isinstance(value.get("entries"), list):
        return value["entries"]
    for field in ("data", "stringData"):
        body = value.get(field)
        if isinstance(body, dict):
            for key in sorted(body):
                if key.endswith(".yaml"):
                    inner = blueprint_entries(body[key])
                    if inner is not None:
                        return inner
    return None


def group_reference(ref):
    """The group name a `!Find [authentik_core.group, [name, X]]` resolves to.

    Returns (name, None) on success, (None, reason) when it cannot be resolved - and an unresolved
    reference is reported, never assumed to be fine.
    """
    if not isinstance(ref, list) or len(ref) != 2:
        return None, "not a !Find [model, [key, value]] pair"
    model, pair = ref
    if model != GROUP_MODEL:
        return None, f"!Find targets {model!r}, not {GROUP_MODEL!r}"
    if not isinstance(pair, list) or len(pair) != 2:
        return None, "!Find selector is not a [key, value] pair"
    key, name = pair
    if key != "name":
        return None, f"group looked up by {key!r}; this gate only resolves lookup by 'name'"
    return name, None


def blueprint_version(value):
    """The version declared by a ConfigMap data value that IS an authentik blueprint, else None.

    `entries` alone is the signal, and that is deliberate: authentik defaults a missing `version`
    to 1 (VERSION_RULE), so a body with `entries` and no `version` is a blueprint as far as the
    worker is concerned. Requiring both keys - the first draft of this gate - made a correct tree
    fail and an unmounted version-less blueprint invisible."""
    if not isinstance(value, str):
        return None
    try:
        parsed = yaml.load(value, Loader=TagTolerantLoader)
    except yaml.YAMLError:
        return None
    if not isinstance(parsed, dict) or "entries" not in parsed:
        return None
    return parsed.get("version", BLUEPRINT_VERSION)


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
    # cm_yaml_keys / cm_blueprint_versions are kept separately so a mounted ConfigMap can be
    # reported as "no .yaml key at all" rather than the vaguer "no blueprint in it", and so a
    # blueprint at the wrong version is named rather than waved through.
    present = set()
    blueprint_cms = set()
    secret_named_blueprints = set()
    cm_yaml_keys = {}
    cm_blueprint_versions = {}
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
            yaml_keys = {k for k in data if k.endswith(".yaml")}
            versions = {}
            for key in sorted(yaml_keys):
                version = blueprint_version(data[key])
                if version is not None:
                    versions[key] = version
            cm_yaml_keys[(ns, name)] = yaml_keys
            cm_blueprint_versions[(ns, name)] = versions
            if versions:
                blueprint_cms.add((ns, name))
        elif name.startswith(SECRET_PREFIX) and name.endswith(SECRET_SUFFIX):
            secret_named_blueprints.add((ns, name))

    failures = []
    checked_mounts = 0
    # (kind, namespace) -> names that release mounts, and the namespaces an authentik release runs
    # in at all. Both feed the tree-wide reverse pass below, which is what catches a blueprint
    # committed into a namespace nothing can mount it from.
    mounted_names = {}
    release_namespaces = set()

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
        release_namespaces.add(ns)
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
            names = {m for m in listed if isinstance(m, str) and m}
            mounted_names.setdefault((kind, ns), set()).update(names)
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
                # Mounted and present: does it actually carry something the worker will discover?
                # ConfigMap only - a Secret's body is sops ciphertext and this gate is keyless.
                if key == "configMaps" and (kind, ns, mount) in present:
                    if not cm_yaml_keys.get((ns, mount)):
                        failures.append(
                            f"{ns}/{name}: {mount!r} is mounted but has no key ending in .yaml, "
                            f"and the worker's discovery glob is **/*.yaml ({DISCOVERY_GLOB}) - "
                            "nothing will ever be applied from it"
                        )
                    elif not cm_blueprint_versions.get((ns, mount)):
                        failures.append(
                            f"{ns}/{name}: {mount!r} is mounted but none of its .yaml keys "
                            f"({', '.join(sorted(cm_yaml_keys[(ns, mount)]))}) parses to a "
                            "mapping with `entries` - nothing will be applied from it"
                        )
                    else:
                        for bad_key, version in sorted(
                            cm_blueprint_versions[(ns, mount)].items()
                        ):
                            if version != BLUEPRINT_VERSION:
                                failures.append(
                                    f"{ns}/{name}: {mount!r}/{bad_key} declares "
                                    f"version {version!r} and authentik skips any blueprint whose "
                                    f"version is not {BLUEPRINT_VERSION} ({VERSION_RULE}) - it "
                                    "mounts, parses, and is never applied"
                                )
                if not auto and mount not in reload_lists[key]:
                    failures.append(
                        f"{ns}/{name}: {mount!r} is mounted but not in the worker's "
                        f"{RELOADER_FOR_KEY[key]} annotation, so an edit lands up to an hour "
                        "late and reads as a no-op (runbook §5)"
                    )

            # The other direction of the drift that bit authentik-opencloud-blueprint: an
            # annotation entry pointing at nothing. Names that exist but are not blueprint
            # mounts are fine - see the docstring's 3b.
            if not auto:
                for stale in sorted(reload_lists[key]):
                    if (kind, ns, stale) not in present:
                        failures.append(
                            f"{ns}/{name}: the worker's {RELOADER_FOR_KEY[key]} annotation names "
                            f"{stale!r} but no {kind} {ns}/{stale} exists - a dead entry that "
                            "reloads nothing"
                        )

    # Reverse direction, tree-wide: a blueprint-bearing object that no authentik release in its own
    # namespace mounts. Secrets are matched on the name convention, ConfigMaps on content.
    for key in MOUNT_KEYS:
        kind = KIND_FOR_KEY[key]
        pool = blueprint_cms if key == "configMaps" else secret_named_blueprints
        for (cns, cname) in sorted(pool):
            if cname in mounted_names.get((kind, cns), set()):
                continue
            if cns not in release_namespaces:
                failures.append(
                    f"{cns}/{cname}: {kind} carries a blueprint but no {CHART} HelmRelease exists "
                    f"in namespace {cns!r}, and the chart mounts by name inside the release's own "
                    "namespace only - nothing can ever mount this"
                )
            else:
                failures.append(
                    f"{cns}/{cname}: {kind} carries a blueprint but is not listed under "
                    f"`blueprints.{key}` of the {CHART} release in {cns} - it will never be applied"
                )

    # --- check 4: every policybinding names a group this tree declares ---------------------------
    # Sources: plaintext blueprint bodies in the built tree, plus the templates on disk. The mounted
    # Secret blueprints are sops ciphertext and stay unread here - the template is their source, and
    # `rerender-authentik-blueprint.sh` without --write is what proves the two still agree.
    declared = set(DECLARED_ELSEWHERE)
    bindings = []  # (where, group name or None, reason it could not be resolved)
    sources = []
    for d in docs:
        if d.get("kind") in ("ConfigMap", "Secret"):
            meta = d.get("metadata") or {}
            sources.append((f"{meta.get('namespace')}/{meta.get('name')}", d))
    templates = sorted((REPO / "authentik").glob("blueprints-*.yaml"))
    if not templates:
        failures.append(
            f"no {TEMPLATE_GLOB} found under {REPO / 'authentik'} - this gate reads bindings from "
            "those files, so finding none means they moved or this scanner broke"
        )
    for tpl in templates:
        sources.append((str(tpl.relative_to(REPO)), tpl.read_text()))

    for where, src in sources:
        entries = blueprint_entries(src)
        if not entries:
            continue
        for entry in entries:
            if not isinstance(entry, dict):
                continue
            model = entry.get("model")
            attrs = entry.get("attrs") or {}
            ids = entry.get("identifiers") or {}
            if model == GROUP_MODEL:
                gname = ids.get("name") or attrs.get("name")
                if isinstance(gname, str) and gname:
                    declared.add(gname)
            elif model == BINDING_MODEL:
                ref = attrs.get("group", ids.get("group"))
                if ref is None:
                    # A `policy:` or `user:` binding. Out of scope: only group references have a
                    # declaration in this tree to check against.
                    continue
                name, why = group_reference(ref)
                bindings.append((where, name, why))

    if templates and not bindings:
        failures.append(
            f"no {BINDING_MODEL} found in any blueprint or template - either the templates moved, "
            "this scanner broke, or every binding was removed. If the last, update this gate rather "
            "than trusting a clean run from a gate that scanned nothing."
        )

    for where, name, why in sorted(bindings, key=lambda b: (b[0], str(b[1]))):
        if why is not None:
            failures.append(
                f"{where}: a {BINDING_MODEL} group reference this gate cannot resolve: {why}. "
                "An unresolvable group reference denies access rather than allowing it, so it is "
                "reported rather than assumed to have resolved."
            )
        elif name not in declared:
            failures.append(
                f"{where}: a {BINDING_MODEL} binds group {name!r}, which no blueprint in this tree "
                f"declares. A binding naming a group that does not exist DENIES rather than allows, "
                f"so the application behind it silently stops admitting people. Declare the group, "
                f"fix the name, or - if the group genuinely lives outside git - add it to "
                f"DECLARED_ELSEWHERE in this file with a citation."
            )

    if failures:
        print("FAIL: authentik blueprint mounts:")
        for line in failures:
            print(f"  {line}")
        return 1

    print(
        f"blueprint-mount-check: {len(releases)} authentik HelmRelease(s), "
        f"{checked_mounts} mount(s) scanned across {len(release_namespaces)} namespace(s); every "
        "blueprint in the tree mounted by name, reload-wired on the worker, and discoverable where "
        "the worker reads it; "
        f"{len(bindings)} policybinding(s) checked against {len(declared)} declared group(s) "
        "(Secret content is never read - see the gate's own docstring)"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
