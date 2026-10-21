#!/usr/bin/env python3
"""grafana-oidc-check: Grafana's OIDC client, authentik's copy of it, the mount, and the host it is
for — all four agreeing.

Grafana's OIDC client is one credential written into four places, and every way they can disagree
looks like a different bug:

  * the rendered blueprint drifts from the reviewed template in authentik/blueprints-grafana.yaml —
    git says one thing, authentik applies another, and no reviewer ever sees the applied artifact;
  * Grafana's copy (tesla-grafana-oidc) and authentik's copy disagree — every login fails with an
    OIDC error that reads like a Grafana bug;
  * nothing mounts the blueprint — valid, inert, and indistinguishable from "the blueprint was never
    written", because the worker only ever reads what the HelmRelease lists;
  * the redirect_uri names a different host than Grafana is served on — authentik refuses the
    callback with a redirect_uri mismatch that Grafana reports as a provider error. This is the one
    that a hostname rename causes, and this repo renames this host once already (grafana. ->
    tesla-boards.), so the check is not theoretical.

It also refuses to report clean when the pieces that make the role mapping work are missing: the
`profile` scope is what puts a `groups` claim in the token, and without it every OIDC login silently
lands as Viewer, which is a permissions bug that presents as working.

Like oidc-check this is reference-driven and refuses to report clean when a Secret will not decrypt.
When Grafana's OIDC values do not exist yet it says so and counts zero, which is honest and empty
rather than a pass over nothing.
"""
import os
import re
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from sopsload import find, load_docs, load_text, load_tolerating_tags, secret_key  # noqa: E402

import yaml  # noqa: E402

# Two Grafanas, one gate. Each variant is the same four-way agreement — reviewed template vs rendered
# blueprint, Grafana's copy vs authentik's copy, mounted vs not, redirect host vs served host — over
# a different set of names. A forked script was declined (spec §9 of the 2026-10-21 Grafana design):
# the failure modes are identical and two scripts drift, which is the thing these gates exist to
# prevent. `tesla` is the default so `make grafana-oidc-check` behaves exactly as it always did.
VARIANTS = {
    "tesla": {
        "TEMPLATE": "authentik/blueprints-grafana.yaml",
        "PLACEHOLDERS": ("GRAFANA_OIDC_CLIENT_ID", "GRAFANA_OIDC_CLIENT_SECRET"),
        "REDIRECT": "https://tesla-boards.titan.arrieta.eu/login/generic_oauth",
        "HOST": "tesla-boards.titan.arrieta.eu",
        "BLUEPRINT_SECRET": "authentik-grafana-blueprint",
        "BLUEPRINT_KEY": "grafana.yaml",
        "APP_SECRET": "tesla-grafana-oidc",
        "APP_NS": "apps",
        "DEPLOY": "tesla-grafana",
        "SLUG": "tesla-boards",
        "SCRIPT": "scripts/setup-grafana-oidc.sh",
    },
    "observability": {
        "TEMPLATE": "authentik/blueprints-observability.yaml",
        "PLACEHOLDERS": ("GRAFANA_OIDC_CLIENT_ID", "GRAFANA_OIDC_CLIENT_SECRET"),
        "REDIRECT": "https://grafana.titan.arrieta.eu/login/generic_oauth",
        "HOST": "grafana.titan.arrieta.eu",
        "BLUEPRINT_SECRET": "authentik-observability-blueprint",
        "BLUEPRINT_KEY": "observability.yaml",
        "APP_SECRET": "observability-grafana-oidc",
        "APP_NS": "observability",
        "DEPLOY": "grafana",
        "SLUG": "observability",
        "SCRIPT": "scripts/setup-observability-grafana.sh",
    },
}


def variant_from(argv):
    """The variant named by --variant=NAME, else tesla. argv[1] stays the tree root."""
    for a in argv[2:]:
        if a.startswith("--variant="):
            name = a.split("=", 1)[1]
            if name not in VARIANTS:
                sys.exit(f"grafana-oidc-check: unknown variant {name!r}; known: {', '.join(VARIANTS)}")
            return VARIANTS[name]
    return VARIANTS["tesla"]


def provider_entry(bp):
    for e in bp.get("entries") or []:
        if e.get("model") == "authentik_providers_oauth2.oauth2provider":
            return e
    return None


def app_entry(bp):
    for e in bp.get("entries") or []:
        if e.get("model") == "authentik_core.application":
            return e
    return None


def container_env(deploy):
    """(env name -> literal value, set of envFrom secret names) for the grafana container."""
    out, from_secrets = {}, set()
    for spec in ((deploy.get("spec") or {}).get("template") or {}).get("spec", {}).get("containers", []):
        for e in spec.get("env") or []:
            out[e.get("name")] = e.get("value")
        for ef in spec.get("envFrom") or []:
            ref = (ef.get("secretRef") or {}).get("name")
            if ref:
                from_secrets.add(ref)
    return out, from_secrets


def main():
    root = sys.argv[1] if len(sys.argv) > 1 else "apply"
    v = variant_from(sys.argv)
    TEMPLATE, PLACEHOLDERS = v["TEMPLATE"], v["PLACEHOLDERS"]
    REDIRECT, HOST = v["REDIRECT"], v["HOST"]
    BLUEPRINT_SECRET, BLUEPRINT_KEY = v["BLUEPRINT_SECRET"], v["BLUEPRINT_KEY"]
    APP_SECRET, APP_NS = v["APP_SECRET"], v["APP_NS"]
    docs = load_docs(root)
    checked = bad = 0

    def fail(msg):
        nonlocal bad
        print(f"FAIL: {msg}")
        bad += 1

    # --- A. the reviewed template --------------------------------------------------------------
    tpl_text = load_text(TEMPLATE)
    if tpl_text is None:
        sys.exit(f"grafana-oidc-check: {TEMPLATE} is missing - the gate has no source of truth to "
                 f"check against; refusing to report clean")
    try:
        tpl = load_tolerating_tags(tpl_text)
    except yaml.YAMLError as exc:
        sys.exit(f"grafana-oidc-check: {TEMPLATE} is not valid YAML: {exc}")
    checked += 1

    pe, ae = provider_entry(tpl), app_entry(tpl)
    if pe is None:
        fail(f"{TEMPLATE} declares no authentik_providers_oauth2.oauth2provider entry")
    if ae is None:
        fail(f"{TEMPLATE} declares no authentik_core.application entry")
    if pe and ae:
        checked += 1
        if (ae.get("attrs") or {}).get("slug") != v["SLUG"]:
            fail(f"the application slug is not {v['SLUG']!r} - with issuer_mode per_provider the "
                 "slug IS the issuer path, so Grafana's configured issuer and authentik's would "
                 "differ, and that failure looks like a bad token, not a bad slug")
        uris = [u.get("url") for u in ((pe.get("attrs") or {}).get("redirect_uris") or [])]
        if uris != [REDIRECT]:
            fail(f"redirect_uris is {uris}, expected exactly ['{REDIRECT}'] - Grafana registers its "
                 f"generic_oauth callback at that path and nowhere else")
        modes = [u.get("matching_mode") for u in ((pe.get("attrs") or {}).get("redirect_uris") or [])]
        if any(m != "strict" for m in modes):
            fail(f"redirect_uri matching_mode is {modes}; a prefix match here is a redirect bypass")
        scopes = [str(m) for m in ((pe.get("attrs") or {}).get("property_mappings") or [])]
        if not any("scope-profile" in s for s in scopes):
            fail("the provider has no scope-profile mapping - `groups` comes only from the profile "
                 "scope mapping, so role_attribute_path would evaluate against a missing claim and "
                 "every OIDC login would silently become Viewer")

    found = set(re.findall(r"\$\{([A-Z_]+)\}", tpl_text))
    checked += 1
    if found != set(PLACEHOLDERS):
        fail(f"{TEMPLATE} placeholders are {sorted(found)}, expected {sorted(PLACEHOLDERS)} - "
             f"setup-grafana-oidc.sh substitutes exactly these two and nothing else")

    # --- B. Grafana's copy, and the rendered artifact ------------------------------------------
    cid, cdata = secret_key(docs, APP_SECRET, APP_NS, "GF_AUTH_GENERIC_OAUTH_CLIENT_ID")
    if cdata is None:
        print(f"grafana-oidc-check: {APP_SECRET} not present - 0 rendered OIDC artifacts to "
              f"reconcile (run {v['SCRIPT']})")
        print(f"grafana-oidc-check: {checked} template check(s) run, {bad} mismatch(es)")
        sys.exit(1 if bad else 0)

    csec, _ = secret_key(docs, APP_SECRET, APP_NS, "GF_AUTH_GENERIC_OAUTH_CLIENT_SECRET")
    if not cid or not csec:
        fail("tesla-grafana-oidc is present but the client id or secret is empty")
    checked += 1

    bp_secret = find(docs, "Secret", BLUEPRINT_SECRET, "auth")
    if bp_secret is None:
        fail(f"Grafana has OIDC credentials but {BLUEPRINT_SECRET} (namespace auth) is not in the "
             f"tree - authentik has no such client, so every Grafana OIDC login will fail")
    else:
        checked += 1
        rendered = (bp_secret.get("stringData") or {}).get(BLUEPRINT_KEY)
        if rendered is None:
            fail(f"{BLUEPRINT_SECRET} has no '{BLUEPRINT_KEY}' key - the worker only picks up keys "
                 f"ending in .yaml, so an empty Secret is indistinguishable from no blueprint")
        else:
            checked += 1
            leftover = re.findall(r"\$\{[A-Z_]+\}", rendered)
            if leftover:
                fail(f"rendered blueprint still contains unsubstituted placeholders {leftover} - "
                     f"authentik would register a client literally named {leftover[0]}")
            try:
                rbp = load_tolerating_tags(rendered) or {}
                rattrs = next((e.get("attrs") or {}) for e in (rbp.get("entries") or [])
                              if e.get("model") == "authentik_providers_oauth2.oauth2provider")
            except (yaml.YAMLError, StopIteration):
                rattrs = {}
            if rattrs.get("client_id") != cid:
                fail(f"authentik's client_id is {rattrs.get('client_id')!r} but Grafana is "
                     f"configured with {cid!r} - the two copies of this credential disagree")
            elif rattrs.get("client_secret") != csec:
                fail(f"authentik's client_secret does not match {APP_SECRET} - every login "
                     "will fail with an OIDC error that reads like a Grafana bug")
            else:
                checked += 1
            expected = (tpl_text.replace("${GRAFANA_OIDC_CLIENT_ID}", cid or "")
                               .replace("${GRAFANA_OIDC_CLIENT_SECRET}", csec or ""))
            try:
                if load_tolerating_tags(rendered) != load_tolerating_tags(expected):
                    fail(f"{BLUEPRINT_SECRET}:{BLUEPRINT_KEY} is not the committed template with "
                         f"the two credentials substituted - the applied artifact has drifted from "
                         f"the reviewed source; re-run {v['SCRIPT']}")
                checked += 1
            except yaml.YAMLError as exc:
                fail(f"rendered blueprint is not valid YAML: {exc}")

    # --- C. is the blueprint actually mounted, and is Grafana wired to it? ----------------------
    hr = find(docs, "HelmRelease", "authentik", "auth")
    if hr is None:
        fail("no HelmRelease authentik/auth found - cannot tell whether the blueprint is mounted")
    else:
        checked += 1
        mounted = (((hr.get("spec") or {}).get("values") or {})
                   .get("blueprints") or {}).get("secrets") or []
        if BLUEPRINT_SECRET in mounted:
            if bp_secret is None:
                fail(f"HelmRelease mounts {BLUEPRINT_SECRET} but that Secret is not in the tree")
        else:
            fail(f"nothing mounts {BLUEPRINT_SECRET}: the worker never sees it, so the blueprint "
                 f"cannot apply. Add it under spec.values.blueprints.secrets")

    deploy = find(docs, "Deployment", v["DEPLOY"], APP_NS)
    if deploy is None:
        fail(f"no Deployment {APP_NS}/{v['DEPLOY']} - cannot check how Grafana is configured")
    else:
        checked += 1
        env, from_secrets = container_env(deploy)
        if APP_SECRET not in from_secrets:
            fail(f"the Grafana Deployment does not envFrom {APP_SECRET} - the client is in the tree "
                 f"and Grafana will never read it")
        checked += 1
        if env.get("GF_AUTH_GENERIC_OAUTH_ENABLED") != "true":
            fail("GF_AUTH_GENERIC_OAUTH_ENABLED is not 'true' - the client exists and nothing uses "
                 "it, which is the quiet half of a half-finished migration")
        if env.get("GF_AUTH_BASIC_ENABLED") != "true":
            fail("GF_AUTH_BASIC_ENABLED is not 'true'. Keep it true through any OIDC rollout: if the "
                 "OIDC config is wrong and basic auth is off, the only way back in is editing the "
                 "admin Secret and restarting Grafana")
        root_url = env.get("GF_SERVER_ROOT_URL") or ""
        if HOST not in root_url:
            fail(f"GF_SERVER_ROOT_URL is {root_url!r} but the OIDC redirect_uri names {HOST} - "
                 f"authentik will refuse the callback with a redirect_uri mismatch")
        checked += 1
        scopes = env.get("GF_AUTH_GENERIC_OAUTH_SCOPES") or ""
        if "profile" not in scopes:
            fail(f"GF_AUTH_GENERIC_OAUTH_SCOPES is {scopes!r} and omits profile - without it there "
                 f"is no groups claim, so role_attribute_path cannot match and every login falls "
                 f"back to the default role")
        if "email" not in scopes:
            fail(f"GF_AUTH_GENERIC_OAUTH_SCOPES is {scopes!r} and omits email - Grafana requires an "
                 f"email for OAuth sign-up and will refuse the login without one")
        checked += 1

    print(f"grafana-oidc-check: {checked} check(s) run, {bad} mismatch(es)")
    sys.exit(1 if bad else 0)


if __name__ == "__main__":
    main()
