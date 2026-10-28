#!/usr/bin/env python3
"""Assert every public apex Ingress here is actually gated, and its gate resolves.

Reads multi-document YAML on stdin - the concatenated `kubectl kustomize` output for every
stage directory, each build terminated by an explicit `---`, the same stream secret-refs,
crd-check and namespace-check consume - plus the path to the source tree as argv[1], used
only to work out which stage built which object. Built objects, not source files, so a name
that only exists after a kustomize transform is still checked.

WHY THIS EXISTS. Whether a public hostname is gated at all is decided by Traefik annotations on an
`Ingress`, and until now nothing in this repo read them. `crd-check` walks
custom resources and an `Ingress` is a core type; `secret-refs` walks workloads and never
looks at an Ingress; `release-secrets` walks `HelmRelease` objects. So the line that gates
`investing-agent.titan.arrieta.eu` behind authentik - added in PR #192 - was guarded by a
comment, and that file said so out loud, twice. A gate whose whole subject is prose is a gate
that gets deleted in a later refactor and stays green. This is `secret-refs` applied one
object type further on, for the annotation class the repo's own headers keep naming as
unguarded.

WHAT IT CHECKS, for every built `Ingress` that serves a host under APEX:

  1. It must carry `traefik.ingress.kubernetes.io/router.middlewares`, or be named in
     NOT_PROXY_GATED below with the reason it is allowed to have no proxy-side gate. Absent
     and unlisted is a public host with nothing in front but whatever the app thinks it has.
  2. Every reference in that annotation must resolve to a `Middleware` this tree builds, in
     the SAME namespace as the Ingress that references it. Traefik resolves a CRD middleware
     against the Ingress's own namespace - the invariant scale-out spec §4 states as "the
     forward-auth Middleware must move with the Ingress", and §9 of the teslamate runbook
     records what ignoring it cost. A reference that does not resolve is not a warning:
     upstream disables the router, so the host 404s.
  3. The reference must be written namespace-qualified (`<ns>-<name>@kubernetescrd`). Every
     reference in the tree is written that way already, and the bare form is the one that
     silently means "whichever namespace this Ingress happens to be in" - which is exactly
     the ambiguity that a namespace move turns into a dangling reference.
  4. The resolved `Middleware` must declare `forwardAuth`. An annotation naming a
     `stripPrefix` satisfies "has a middleware" while gating nothing, which is the failure
     this gate exists to prevent, so it is not allowed to pass.

VACUITY. It refuses to report clean when it found nothing to check - no Ingress, no apex
Ingress, no declared Middleware, or an allow-list entry that no longer matches anything. A
gate that passes on an empty set is worse than no gate, and an allow-list entry left behind
by a deleted Ingress is a hole nobody would re-justify.

WHAT IT DOES NOT PROVE, in order of how much it matters:

  * It does not prove the policy behind a resolved reference. A `forwardAuth` pointing at an
    authentik outpost whose provider has no `access_group` gates this host open to every
    authenticated account, and that is a row in authentik's database, not in this tree.
    `apply/50-apps/investing-agent/investing-agent.yaml` states the inherited policy because
    no gate here can.
  * It does not read `router.entrypoints`. The `websecure` pin is the same class of
    annotation-shaped decision and is still guarded by prose alone; enforcing it would need a
    second allow-list of hosts that tolerate cleartext, and `http://meals.titan.arrieta.eu/`
    answering 200 today says that list is not empty. Naming that gap rather than half-closing
    it is deliberate.
  * It does not prove a gated host is gated on every path. An `IngressRoute` or a
    `skip_path_regex` on the outpost can open a path around the middleware, and neither is
    visible from an `Ingress` annotation.
  * It cannot see a live cluster. A Middleware that exists live but is not declared here -
    or the reverse, a tree that declares one Flux never applies - passes or fails on the tree
    as written. `make kustomize-listing` is the gate for the second case, not this one.

THE STAGE NOTE is reported, not failed, and it is the one finding here that is a judgement
rather than a fact. A reference whose Middleware is built by a different top-level stage than
its Ingress works, but it makes apply order depend on something `dependsOn` does not
declare: `stage-apps.yaml` and `stage-tesla.yaml` each depend on certificates and databases
and neither depends on the other, so on a cold restore their order is undefined and the
reference is briefly unresolvable. That is fail-closed - the router is disabled, the host
404s, and it self-heals - so it is a note and not a red. It is printed every run because a
hazard that is only written in a comment is a hazard that gets discovered during a restore.
"""
import sys
from pathlib import Path

import yaml

APEX = "titan.arrieta.eu"
MIDDLEWARE_ANNOTATION = "traefik.ingress.kubernetes.io/router.middlewares"

# Apex Ingresses deliberately carrying no proxy-side gate. Keyed by (namespace, Ingress name)
# rather than by host, because `tesla.titan.arrieta.eu` is served by two Ingresses and only one
# of them is allowed to be open. Every entry is a transcription of a decision recorded
# elsewhere in this tree, with the citation in its reason; an entry with no citation is a hole
# nobody justified.
NOT_PROXY_GATED = {
    ("coder", "coder"): "authentik OIDC in-app; CODER_OIDC_* on the Deployment and the password "
                        "path disabled (apply/50-apps/coder/coder.yaml)",
    ("open-webui", "open-webui"): "declined forward-auth deliberately, spec D3 "
                                  "(docs/superpowers/specs/2026-10-20-titan-open-webui-design.md); "
                                  "ENABLE_LOGIN_FORM=false and group-mapped roles",
    ("mealie", "mealie"): "Mealie is OIDC-only with ALLOW_PASSWORD_LOGIN=false "
                          "(apply/50-apps/mealie/mealie.yaml)",
    ("files", "opencloud"): "oCIS proxy authenticates against authentik OIDC, PROXY_OIDC_* "
                            "(apply/50-apps/opencloud/opencloud.yaml)",
    ("files", "collabora"): "no user-facing login of its own; its only relationship is the WOPISrc "
                            "handed by opencloud-collaboration:9300 "
                            "(header, apply/50-apps/opencloud/collabora.yaml)",
    ("apps", "tesla-wellknown"): "must stay public: Tesla re-fetches the application public key from "
                                 "/.well-known and pairing fails when it 404s "
                                 "(apply/60-tesla/wellknown.yaml)",
    ("apps", "tesla-auth-callback"): "the OAuth redirect URI registered with Tesla; gating it breaks "
                                     "the first sign-in and it exchanges no code "
                                     "(apply/60-tesla/auth-callback.yaml)",
    ("apps", "tesla-streaming"): "wss intake whose public host exists only for a real certificate; "
                                 "its caller is the in-cluster forwarder "
                                 "(apply/60-tesla/streaming.yaml)",
}


def apex_host(doc):
    """Return the first host this Ingress serves under APEX, or None."""
    for rule in ((doc.get("spec") or {}).get("rules") or []):
        host = rule.get("host") if isinstance(rule, dict) else None
        if host == APEX or (host or "").endswith("." + APEX):
            return host
    return None


def stage_of(source_root):
    """Map (kind, namespace, name) -> top-level stage directory, from the source tree.

    Only used for the cross-stage note. Source files are read because the built stream on
    stdin has already lost every path; a kustomize transform that renamed an Ingress or a
    Middleware would make this map wrong, which is why the note it feeds is informational.
    """
    mapping = {}
    for path in sorted(Path(source_root).rglob("*.yaml")):
        try:
            docs = list(yaml.safe_load_all(path.read_text()))
        except (yaml.YAMLError, OSError, UnicodeDecodeError):
            continue  # sops-encrypted files parse to something with no `kind`; skip them.
        for doc in docs:
            if not isinstance(doc, dict) or doc.get("kind") not in ("Ingress", "Middleware"):
                continue
            meta = doc.get("metadata") or {}
            parts = path.parts
            stage = next((p for p in parts[parts.index("apply") + 1:] if not p.endswith(".yaml")), "?")
            mapping.setdefault((doc["kind"], meta.get("namespace"), meta.get("name")), (stage, str(path)))
    return mapping


def main():
    if len(sys.argv) != 2:
        print("usage: ingress-auth-check.py <source-tree-root> < built-yaml-stream")
        return 2
    try:
        docs = [doc for doc in yaml.safe_load_all(sys.stdin) if doc]
    except yaml.YAMLError as exc:
        print(f"FAIL: stdin is not parseable YAML: {exc}")
        return 1

    stages = stage_of(sys.argv[1])

    middlewares = {}
    for doc in docs:
        if doc.get("kind") == "Middleware":
            meta = doc.get("metadata") or {}
            middlewares[(meta.get("namespace"), meta.get("name"))] = doc
    if not middlewares:
        print("FAIL: no Middleware declared in the build - ingress-auth cannot pass vacuously")
        return 1

    ingresses = [doc for doc in docs if doc.get("kind") == "Ingress"]
    if not ingresses:
        print("FAIL: no Ingress in the build - ingress-auth cannot pass vacuously")
        return 1

    failures = []
    notes = []
    gated = 0
    allow_used = set()
    apex_count = 0

    for doc in ingresses:
        meta = doc.get("metadata") or {}
        ns, name = meta.get("namespace"), meta.get("name")
        host = apex_host(doc)
        if host is None:
            continue
        apex_count += 1
        where = f"Ingress {ns}/{name} ({host})"

        raw = ((meta.get("annotations") or {}).get(MIDDLEWARE_ANNOTATION) or "").strip()
        refs = [part.strip() for part in raw.split(",") if part.strip()]
        if not refs:
            if (ns, name) in NOT_PROXY_GATED:
                allow_used.add((ns, name))
                continue
            failures.append(f"{where}: no {MIDDLEWARE_ANNOTATION} and no entry in NOT_PROXY_GATED")
            continue

        gated += 1
        for ref in refs:
            name_part, _, provider = ref.partition("@")
            if provider != "kubernetescrd":
                failures.append(f"{where}: reference {ref!r} is not a CRD middleware; only "
                                "@kubernetescrd is resolvable from this tree")
                continue
            if not name_part.startswith(f"{ns}-"):
                failures.append(f"{where}: reference {ref!r} must be written namespace-qualified as "
                                f"{ns}-<name>@kubernetescrd; the bare form resolves against whichever "
                                "namespace the Ingress lands in")
                continue
            key = (ns, name_part[len(ns) + 1:])
            target = middlewares.get(key)
            if target is None:
                failures.append(f"{where}: reference {ref!r} names no Middleware this tree builds in "
                                f"namespace {ns}; an unresolvable reference disables the router and the "
                                "host 404s")
                continue
            if "forwardAuth" not in ((target.get("spec") or {}) or {}):
                failures.append(f"{where}: Middleware {ns}/{key[1]} is not a forwardAuth middleware, so "
                                "the annotation gates nothing")
                continue
            ingress_stage = stages.get(("Ingress", ns, name), ("?", ""))[0]
            mw_stage = stages.get(("Middleware", ns, key[1]), ("?", ""))[0]
            if ingress_stage != mw_stage:
                notes.append(f"NOTE: {where} references {ref!r}, built by stage {mw_stage!r} while the "
                             f"Ingress is built by {ingress_stage!r}. Works, but neither stage depends "
                             "on the other, so a cold restore can leave the reference briefly "
                             "unresolvable and the host 404ing.")

    stale = set(NOT_PROXY_GATED) - allow_used
    for ns, name in sorted(stale):
        failures.append(f"NOT_PROXY_GATED names {ns}/{name}, which no longer matches any apex Ingress; "
                        "delete the entry or say why it came back")

    if failures:
        print("FAIL: a public apex Ingress is not gated, or its gate does not resolve:")
        for line in failures:
            print(f"  {line}")
        return 1

    unused = len(NOT_PROXY_GATED) - len(allow_used)
    print(f"ingress-auth: {apex_count} apex Ingress object(s) scanned; {gated} gated by a resolvable "
          f"forwardAuth middleware, {len(allow_used)} allow-listed as deliberately not proxy-gated"
          + (f", {unused} allow-list entry(ies) for non-apex Ingresses" if unused else ""))
    for note in notes:
        print(f"  {note}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
