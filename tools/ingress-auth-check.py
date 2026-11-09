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
  5. If it is named in PIN_REQUIRED below, it must pin `router.entrypoints: websecure`. For those
     hosts the pin is half of the admission story: an unpinned Ingress produces a router per entrypoint,
     so a forwardAuth there also runs on cleartext :80 and an in-app login there also serves sessions
     in the clear. A dropped pin makes the reason above it a false statement. It is a failure, not a
     paragraph.

Rule 6 is not per-Ingress. It walks every `forwardAuth` `Middleware` in the build and demands each one
is the canonical outpost gate (OUTPOST_CANONICAL below), a field-for-field copy of it, or named in
OTHER_FORWARD_AUTH with the reason it is a different endpoint. This is the gate for the hand copy in
`apply/50-apps/gatus/gatus.yaml`: a copy that drifts is a copy that silently means something else, and
both copies are Flux-owned, so the tree - not the live cluster - is the whole truth about them.

VACUITY. It refuses to report clean when it found nothing to check - no Ingress, no apex
Ingress, no declared Middleware, an allow-list entry that no longer matches anything, an empty
PIN_REQUIRED, no canonical outpost Middleware, a forwardAuth that is neither the canonical nor declared
in OTHER_FORWARD_AUTH, or an OTHER_FORWARD_AUTH entry that no longer matches anything. A gate that
passes on an empty set is worse than no gate, and an allow-list entry left behind by a deleted Ingress
is a hole nobody would re-justify.

WHAT IT DOES NOT PROVE, in order of how much it matters:

  * It does not prove the policy behind a resolved reference. A `forwardAuth` pointing at an
    authentik outpost whose provider has no `access_group` gates this host open to every
    authenticated account, and that is a row in authentik's database, not in this tree.
    `apply/50-apps/investing-agent/investing-agent.yaml` states the inherited policy because
    no gate here can.
  * It reads `router.entrypoints` only for the hosts named in PIN_REQUIRED. Every other apex host in
    the tree is still free to serve cleartext, and several do - `http://meals.titan.arrieta.eu/`
    answers 200 today. Extending the rule past the hosts whose allow-list justification depends on
    the pin would need a per-host cleartext decision for each of the others, and that is a decision
    this gate must not make by accident.
  * Rule 6 compares the tree to itself. It proves every copy in git matches the canonical in git; it
    cannot prove the live Middleware still matches either, because an out-of-band `kubectl edit` leaves
    no trace here. That is the hole `make dry-run` and AGENTS.md's live-drift rule exist for, not this
    one.
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
PIN_ANNOTATION = "traefik.ingress.kubernetes.io/router.entrypoints"

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
    ("apps", "portfolio-prism"): "the app authenticates itself against authentik — OIDC Authorization "
                                 "Code + PKCE with its own session cookie (AUTH_MODE=oidc on the "
                                 "Deployment, apply/50-apps/portfolio-prism/portfolio-prism.yaml). A "
                                 "forwardAuth here would add a second IdP round trip per session and "
                                 "put the outpost cookie's refresh behaviour (issue #243) in the path "
                                 "of a host that does not need it. WHO may sign in is a policy binding "
                                 "to titan-family on the portfolio-prism Application "
                                 "(authentik/blueprints-portfolio-prism.yaml), which is the whole "
                                 "group gate: the app has no authorization model beyond a valid "
                                 "session, and this repo cannot see that binding.",
    ("observability", "grafana"): "authentik OIDC in-app; GF_AUTH_GENERIC_OAUTH_* with auto_login, and "
                                  "the `observability` application is bound to titan-family / "
                                  "titan-grafana-admins so outsiders are refused at the IdP. The "
                                  "forwardAuth Middleware that used to sit here was REMOVED 2026-11-05, "
                                  "not forgotten: the outpost cookie only refreshes on a top-level "
                                  "navigation, so it 302'd every XHR panel poll and the boards went "
                                  "empty on a timer (apply/50-apps/grafana/grafana.yaml, "
                                  "docs/grafana-runbook.md \u00a710)",
    ("apps", "tesla-grafana"): "authentik OIDC in-app; GF_AUTH_GENERIC_OAUTH_* with auto_login on the "
                               "tesla-grafana Deployment, and the `tesla-boards` application is bound "
                               "to titan-family / titan-tesla-grafana-admins so outsiders are refused "
                               "at the IdP (asserted by make grafana-oidc-check). The forwardAuth "
                               "Middleware that used to sit here was REMOVED 2026-11-05, not forgotten: "
                               "it is the same Grafana with the same defect as observability/grafana "
                               "above, so the outpost cookie aged out and 302'd every XHR panel poll "
                               "(apply/60-tesla/grafana.yaml, docs/grafana-runbook.md \u00a710, "
                               "issue #243)",
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
    # Both Home Assistant passthroughs, migrated from ../k8s-techdelivery 2026-11-02. The migration
    # spec §3.2 demanded an explicit HA sub-decision rather than an inherited default, and the operator
    # made it in issue #112: HA authenticates natively and that is considered sufficient. It is also
    # the parity answer, not a regression — T0a measured chiclana-hass answering 200 unauthenticated on
    # the VPS and hass answering 400 on every path, so no working gate existed to copy. HA's companion
    # apps do not follow a 302 to an external IdP and its websockets are what proxy auth breaks, so an
    # outpost would have bought nothing and cost the phones. The whole edge is now HA's own login; see
    # each file's Ingress header, and note both pin router.entrypoints: websecure because of it.
    ("apps", "home-assistant-home-ingress"): "no proxy-side gate by operator decision 2026-11-02; Home "
                                             "Assistant authenticates natively and its own login is "
                                             "considered sufficient (issue #112; "
                                             "apply/50-apps/home-hass/home-hass.yaml)",
    ("apps", "home-assistant-chiclana-ingress"): "same decision as home-assistant-home-ingress, and "
                                                 "T0a measured this host answering 200 unauthenticated "
                                                 "on the VPS, so a gate here would be a behaviour "
                                                 "change rather than parity (issue #112; "
                                                 "apply/50-apps/chiclana-hass/chiclana-hass.yaml)",
}

# The `websecure` pin, asserted for the hosts whose admission story depends on it.
#
# WHY THIS IS A FAILURE AND NOT A NOTE. Traefik attaches a middleware to every router its Ingress
# produces, and an unpinned Ingress produces one router per entrypoint. This cluster runs no
# HTTP->HTTPS redirect (the ports.web.http.redirections.entryPoint note in
# apply/20-infra/traefik/traefik.yaml) and port 80 is published, so an unpinned host answers in
# cleartext. For the ten hosts below that is not untidiness. Four of them (both Grafanas, both Home
# Assistant passthroughs) are allowed to have no proxy-side gate ONLY because the application behind
# them authenticates on its own, and an application that authenticates over cleartext hands the session
# - the Grafana session, the Home Assistant long-lived token - to anyone on the path. The other six
# (llm, investing-agent, teslamate, bentopdf, vert-sh, gatus) do carry a forwardAuth, and an unpinned
# Ingress runs that gate on :80 as well, so the outpost cookie, the hermes session, the TeslaMate
# session and the llm bearer token travel in the clear beside the HTTPS router. Either way, delete the
# pin and the row above stops being a true statement while this gate still prints clean, which is the
# exact defect this file exists to close.
#
# WHY ONLY TEN. The other apex hosts are unpinned today (coder, open-webui, opencloud, collabora,
# mealie, and the two tesla protocol hosts whose paths have to answer for Tesla's own fetches) and each
# needs its own cleartext decision, made on its own evidence. Demanding the pin everywhere would either
# fail on all of them or get widened into a skip list, and either outcome teaches the next person to
# distrust the gate. bentopdf, vert-sh and gatus joined this set on 2026-11-06 rather than joining the
# unpinned list above, because all three already pin websecure in git: a pin that is already there and
# asserted by nothing is a pin the next person deletes on the assumption that nothing reads it.
PIN_REQUIRED = {
    ("observability", "grafana"): "its NOT_PROXY_GATED row says authentik OIDC in-app is the gate; "
                                  "GF_AUTH_BASIC_ENABLED is also true, so an unpinned router serves "
                                  "the local admin login form and /api/health in the clear "
                                  "(apply/50-apps/grafana/grafana.yaml, docs/grafana-runbook.md \u00a710)",
    ("apps", "tesla-grafana"): "same shape and same reasoning as observability/grafana above "
                               "(apply/60-tesla/grafana.yaml, issue #243)",
    ("llm", "llm"): "the bearer token is the only credential on this host and a cleartext router "
                    "would carry it in the clear (apply/50-apps/llm/llm.yaml)",
    ("apps", "investing-agent"): "forward-auth plus hermes' own session; unpinned, both travel over "
                                 "cleartext :80 beside the gated HTTPS router "
                                 "(apply/50-apps/investing-agent/investing-agent.yaml)",
    ("apps", "portfolio-prism"): "its NOT_PROXY_GATED row says the app authenticates in-app, and what "
                                 "travels is the app's own session cookie, set Secure unconditionally. "
                                 "Unpinned, the SPA is served over cleartext :80 and every API call "
                                 "401s into a login redirect loop — the app has no http production "
                                 "path, so there is nothing for a cleartext router to serve correctly "
                                 "(apply/50-apps/portfolio-prism/portfolio-prism.yaml)",
    ("apps", "teslamate"): "the forwardAuth is the only group gate this host has, and unpinned it ran "
                           "on :80 too, so the outpost cookie and the TeslaMate session both travelled "
                           "in the clear; pinned 2026-11-05 in the review of #246 "
                           "(apply/60-tesla/teslamate.yaml, docs/teslamate-runbook.md \u00a79)",
    ("apps", "home-assistant-home-ingress"): "Home Assistant authenticates natively, so its session "
                                             "and any long-lived access token are the only gate and "
                                             "must not be offered on :80 (issue #112; "
                                             "apply/50-apps/home-hass/home-hass.yaml)",
    ("apps", "home-assistant-chiclana-ingress"): "same decision and same reasoning as "
                                                 "home-assistant-home-ingress (issue #112; "
                                                 "apply/50-apps/chiclana-hass/chiclana-hass.yaml)",
    ("apps", "bentopdf"): "forward-auth to the shared outpost and nothing else on the host, so unpinned "
                          "the outpost cookie travels in the clear on the :80 router beside the gated "
                          "HTTPS one (apply/50-apps/bentopdf/bentopdf.yaml)",
    ("apps", "vert-sh"): "same shape as apps/bentopdf above: forward-auth to the shared outpost and no "
                         "other credential (apply/50-apps/vert-sh/vert-sh.yaml)",
    ("gatus", "gatus"): "same shape again, and what it protects is a rendered map of the internal "
                        "network, so its session is worth having (apply/50-apps/gatus/gatus.yaml)",
}

# The canonical outpost forwardAuth, and the rule for every other one in the build.
#
# WHY A COPY NEEDS A GATE AT ALL. `apply/50-apps/gatus/gatus.yaml` carries a hand copy of
# `apps/teslamate-auth` because Traefik resolves a CRD middleware in the Ingress's own namespace and
# `gatus` is not `apps`. The original is NOT generated by authentik - Flux owns it (measured
# 2026-11-06: no ownerReferences, `kustomize.toolkit.fluxcd.io/name=tesla`) and
# `apply/60-tesla/teslamate.yaml:172` is its source of truth - so the only way the two diverge is a
# commit, and a commit is exactly what a gate here can catch. `trustForwardHeader` is the field that
# matters most: the embedded outpost picks the provider from X-Forwarded-Host, so a copy that loses it
# stops resolving the host and every consumer of the shared outpost 403s behind a healthy-looking
# login page.
OUTPOST_CANONICAL = ("apps", "teslamate-auth")

# forwardAuth Middlewares deliberately NOT the outpost, each with the reason it is a different
# endpoint. An entry here is a decision, so an entry that matches nothing fails.
OTHER_FORWARD_AUTH = {
    ("llm", "bearer-auth"): "the hermes bearer-token gate: a throwaway nginx rather than the authentik "
                            "outpost, so it shares no fields with the canonical "
                            "(apply/50-apps/llm/llm.yaml)",
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
    if not PIN_REQUIRED:
        print("FAIL: PIN_REQUIRED is empty - the websecure pin is load-bearing for named hosts and "
              "this gate cannot pass vacuously by forgetting them")
        return 1

    failures = []
    notes = []
    gated = 0
    allow_used = set()
    pin_used = set()
    apex_count = 0

    # Rule 6: every forwardAuth in the build is the canonical outpost gate, a field-for-field copy of
    # it, or declared in OTHER_FORWARD_AUTH as a deliberately different endpoint.
    canonical = middlewares.get(OUTPOST_CANONICAL)
    canonical_fa = ((canonical.get("spec") or {}).get("forwardAuth") or {}) if canonical else {}
    forward_auth_keys = {(ns, name) for (ns, name), doc in middlewares.items()
                         if (doc.get("spec") or {}).get("forwardAuth")}
    copies = []
    if canonical is None:
        failures.append(f"no Middleware {OUTPOST_CANONICAL[0]}/{OUTPOST_CANONICAL[1]} in the build - it is "
                        "the canonical outpost forwardAuth that every copy is compared against, so rule 6 "
                        "cannot pass vacuously by renaming it")
    elif not canonical_fa:
        failures.append(f"Middleware {OUTPOST_CANONICAL[0]}/{OUTPOST_CANONICAL[1]} declares no forwardAuth, "
                        "so there is nothing for rule 6 to compare copies against")
    for (ns, name), doc in sorted(middlewares.items()):
        fa = (doc.get("spec") or {}).get("forwardAuth")
        if not fa or not canonical_fa:
            continue  # not a forwardAuth, or no canonical to compare against (already failed)
        if (ns, name) == OUTPOST_CANONICAL or (ns, name) in OTHER_FORWARD_AUTH:
            continue
        if fa.get("address") != canonical_fa.get("address"):
            failures.append(f"Middleware {ns}/{name} is a forwardAuth that is neither the canonical outpost "
                            f"gate nor named in OTHER_FORWARD_AUTH; its address is {fa.get('address')!r}. "
                            "Either it is a different endpoint and needs an entry there with a reason, or "
                            "it is a copy and its address is wrong")
            continue
        copies.append((ns, name))
        for field in sorted(set(canonical_fa) | set(fa)):
            if fa.get(field) != canonical_fa.get(field):
                failures.append(f"Middleware {ns}/{name} is a hand copy of "
                                f"{OUTPOST_CANONICAL[0]}/{OUTPOST_CANONICAL[1]} but {field} differs: "
                                f"{fa.get(field)!r} against {canonical_fa.get(field)!r}. Both are "
                                "Flux-owned, so fix the copy in git or record why they should differ")
    for ns, name in sorted(set(OTHER_FORWARD_AUTH) - forward_auth_keys):
        failures.append(f"OTHER_FORWARD_AUTH names {ns}/{name}, which no longer matches any forwardAuth "
                        "Middleware in the build; delete the entry or say why it came back")

    for doc in ingresses:
        meta = doc.get("metadata") or {}
        ns, name = meta.get("namespace"), meta.get("name")
        host = apex_host(doc)
        if host is None:
            continue
        apex_count += 1
        where = f"Ingress {ns}/{name} ({host})"

        pin = ((meta.get("annotations") or {}).get(PIN_ANNOTATION) or "").strip()
        if (ns, name) in PIN_REQUIRED:
            pin_used.add((ns, name))
            if pin != "websecure":
                failures.append(f"{where}: PIN_REQUIRED demands {PIN_ANNOTATION}=websecure and it is "
                                f"{pin!r}. {PIN_REQUIRED[(ns, name)]}")

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
    for ns, name in sorted(set(PIN_REQUIRED) - pin_used):
        failures.append(f"PIN_REQUIRED names {ns}/{name}, which no longer matches any apex Ingress; "
                        "delete the entry or say why the host moved")

    if failures:
        print("FAIL: a public apex Ingress is not gated, or its gate does not resolve:")
        for line in failures:
            print(f"  {line}")
        return 1

    unused = len(NOT_PROXY_GATED) - len(allow_used)
    print(f"ingress-auth: {apex_count} apex Ingress object(s) scanned; {gated} gated by a resolvable "
          f"forwardAuth middleware, {len(allow_used)} allow-listed as deliberately not proxy-gated, "
          f"{len(pin_used)} pinned to websecure where the admission story depends on it, "
          f"{len(copies)} hand copy(ies) of the outpost forwardAuth all matching the canonical"
          + (f", {unused} allow-list entry(ies) for non-apex Ingresses" if unused else ""))
    for note in notes:
        print(f"  {note}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
