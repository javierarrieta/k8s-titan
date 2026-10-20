#!/usr/bin/env python3
"""Fail if open-webui's OIDC wiring has drifted apart.

Four things have to agree and nothing else ties them together:

  1. authentik/blueprints-open-webui.yaml  - the reviewed template, with ${...} placeholders
  2. apply/10-secrets/authentik-open-webui-blueprint.yaml - the rendered artifact authentik applies
  3. apply/50-apps/open-webui/open-webui.yaml - the app's own copy of the client id/secret
  4. the HelmRelease actually mounting the blueprint

Item 4 is the one that burned this cluster before: docs/authentik-runbook.md §5 records a blueprint
that was committed, reviewed and green, and never mounted - indistinguishable from one never written.
Item 3 is the same class of failure with a different symptom: coder's client id drifted from the
blueprint's and nothing noticed (docs/coder-oidc-federation-runbook.md §4).

It also checks the two settings that turn a working login into a silent 403, because both defaults
are traps: OAUTH_ROLES_CLAIM must be `groups` for OAUTH_ADMIN_ROLES to mean anything, and
OAUTH_ALLOWED_ROLES left at its default `user,admin` matches no authentik group name and denies
every non-admin.

Fixtures may be plaintext; real secrets are sops-encrypted. A file that looks encrypted but does not
decrypt is reported, never silently skipped.
"""
import argparse
import os
import re
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from sopsload import find, load_docs, load_tolerating_tags, secret_key  # noqa: E402

HOST = "open-webui.titan.arrieta.eu"
# Both candidate callback paths, each strict. Open WebUI computes its own redirect URI with
# request.url_for('oauth_login_callback', provider='oidc') (utils/oauth.py:1919 at v0.12.3), and
# main.py:2932-2933 binds TWO routes to that handler name: /oauth/{provider}/login/callback (the
# current path) and /oauth/{provider}/callback (the legacy one). Starlette's url_for returns the
# FIRST matching route and decorator order applies bottom-up, so the legacy path is the one the app
# actually sends - but that is an inference from source, not a measurement, so both are registered
# and the first real login narrows this list. A prefix match would be a redirect bypass, hence strict.
REDIRECTS = [f"https://{HOST}/oauth/oidc/callback",
             f"https://{HOST}/oauth/oidc/login/callback"]
PLACEHOLDERS = ("${OPEN_WEBUI_OIDC_CLIENT_ID}", "${OPEN_WEBUI_OIDC_CLIENT_SECRET}")


def provider_of(entries, name="open-webui"):
    for e in entries:
        if e.get("model", "").endswith("oauth2provider") and e.get("identifiers", {}).get("name") == name:
            return e.get("attrs", {})
    return None


def env_of(deploy, name):
    for c in (((deploy.get("spec") or {}).get("template") or {}).get("spec") or {}).get("containers", []):
        for env in c.get("env") or []:
            if env.get("name") == name:
                return env.get("value")
    return None


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--root", default="apply", help="tree to scan (a fixture root for tests)")
    args = ap.parse_args()

    docs = load_docs(args.root)
    failures = []

    def fail(msg):
        failures.append(msg)
        print("FAIL:", msg)

    # --- the blueprint: template, rendered artifact, and the mount ---------------------------
    tpl_path = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
                            "authentik", "blueprints-open-webui.yaml")
    if not os.path.exists(tpl_path):
        fail(f"no reviewed template at {tpl_path}")
        tpl = None
    else:
        tpl = load_tolerating_tags(open(tpl_path).read())

    prov = provider_of(tpl["entries"]) if tpl else None
    if prov is None:
        fail("blueprints-open-webui.yaml declares no oauth2provider named open-webui")

    bp = find(docs, "Secret", "authentik-open-webui-blueprint", "auth")
    if bp is None:
        fail("no Secret authentik-open-webui-blueprint in namespace auth - the blueprint is not in the tree")
        rendered = None
    else:
        rendered, _ = secret_key(docs, "authentik-open-webui-blueprint", "auth", "open-webui.yaml")
        if rendered is None:
            fail("Secret authentik-open-webui-blueprint has no key open-webui.yaml - the worker only "
                 "picks up keys ending in .yaml")

    if rendered is not None:
        rprov = provider_of(load_tolerating_tags(rendered)["entries"])
        if rprov is None:
            fail("the rendered blueprint has no oauth2provider named open-webui")
        else:
            for ph in PLACEHOLDERS:
                if ph in rendered:
                    fail(f"the rendered blueprint still carries {ph} - it was committed before "
                         "scripts/setup-open-webui-secrets.sh substituted it")
            if tpl is not None:
                # The rendered artifact must be the template with ONLY the two placeholders filled.
                expect = tpl_path
                want = open(expect).read()
                for ph in PLACEHOLDERS:
                    want = want.replace(ph, rprov.get("client_id" if "CLIENT_ID" in ph else "client_secret") or "")
                if want != rendered:
                    fail("the rendered blueprint is not the reviewed template plus the credentials - "
                         "someone edited one file and not the other")
            uris = sorted(u.get("url") for u in (rprov.get("redirect_uris") or []))
            if uris != sorted(REDIRECTS):
                fail(f"redirect_uris are {uris}, expected {sorted(REDIRECTS)}")
            if any((u.get("matching_mode") or "strict") != "strict" for u in (rprov.get("redirect_uris") or [])):
                fail("a redirect_uri is not matching_mode: strict - a prefix match is a redirect bypass")
            if "profile" not in " ".join(str(m) for m in (rprov.get("property_mappings") or [])):
                fail("the provider's property_mappings do not include the profile scope, so the "
                     "`groups` claim open-webui's role mapping reads will not be in the token")

    hr = find(docs, "HelmRelease", "authentik", "auth")
    if hr is None:
        fail("no HelmRelease authentik/auth")
    else:
        mounted = ((hr["spec"].get("values").get("blueprints") or {}).get("secrets") or [])
        if "authentik-open-webui-blueprint" not in mounted:
            fail("the HelmRelease does not mount authentik-open-webui-blueprint, so authentik never "
                 "reads it - mounting is not applying, but not mounting is definitely not applying")

    # --- open-webui's own copy ---------------------------------------------------------------
    dep = find(docs, "Deployment", "open-webui", "open-webui")
    if dep is None:
        fail("no Deployment open-webui/open-webui")
    else:
        if env_of(dep, "OAUTH_PROVIDER_NAME") != "authentik":
            fail("OAUTH_PROVIDER_NAME is not authentik")
        if env_of(dep, "ENABLE_LOGIN_FORM") != "false":
            fail("ENABLE_LOGIN_FORM is not false - a local password form next to SSO is a second, "
                 "unbacked door")
        if env_of(dep, "ENABLE_OAUTH_SIGNUP") != "true":
            fail("ENABLE_OAUTH_SIGNUP is not true - authentik users would land on a disabled signup page")
        want_prov = f"https://auth.titan.arrieta.eu/application/o/open-webui/.well-known/openid-configuration"
        if env_of(dep, "OPENID_PROVIDER_URL") != want_prov:
            fail(f"OPENID_PROVIDER_URL is not {want_prov}")
        if "auth.titan.arrieta.eu/application/o/open-webui/" not in (env_of(dep, "OPENID_PROVIDER_URL") or ""):
            fail("OPENID_PROVIDER_URL does not name the per-provider issuer")
        if env_of(dep, "OAUTH_ROLES_CLAIM") != "groups":
            fail("OAUTH_ROLES_CLAIM is not groups - OAUTH_ADMIN_ROLES would then read a claim "
                 "authentik does not send")
        if env_of(dep, "OAUTH_ADMIN_ROLES") != "authentik Admins":
            fail("OAUTH_ADMIN_ROLES is not 'authentik Admins'")
        allowed = env_of(dep, "OAUTH_ALLOWED_ROLES")
        if allowed in (None, "user,admin"):
            fail(f"OAUTH_ALLOWED_ROLES is {allowed!r}; with OAUTH_ROLES_CLAIM=groups the default "
                 "matches no authentik group and 403s every non-admin")
        if env_of(dep, "WEBUI_URL") != f"https://{HOST}":
            fail(f"WEBUI_URL is not https://{HOST} - open-webui builds its own redirect URI from it")

        # The app's client id/secret must equal authentik's, and they arrive through envFrom, so the
        # Secret is the thing to read.
        names = [s.get("secretRef", {}).get("name")
                 for s in (dep["spec"]["template"]["spec"]["containers"][0].get("envFrom") or [])]
        sec = None
        for n in names:
            cand = find(docs, "Secret", n, "open-webui")
            if cand is not None:
                for k in ("OAUTH_CLIENT_ID", "OAUTH_CLIENT_SECRET"):
                    if (cand.get("stringData") or {}).get(k) is not None or (cand.get("data") or {}).get(k) is not None:
                        sec = cand
        if sec is None:
            fail(f"no Secret mounted into open-webui by envFrom carries OAUTH_CLIENT_ID/OAUTH_CLIENT_SECRET "
                 f"(envFrom names: {names})")
        else:
            for key, bp_key in (("OAUTH_CLIENT_ID", "client_id"), ("OAUTH_CLIENT_SECRET", "client_secret")):
                app_val, _ = secret_key(docs, sec["metadata"]["name"], "open-webui", key)
                if app_val is None:
                    fail(f"{sec['metadata']['name']} has no {key}")
                elif rendered is not None and rprov and app_val != rprov.get(bp_key):
                    fail(f"open-webui's {key} does not match the blueprint's {bp_key} - the login will "
                         "fail with invalid_client, and the two files are edited apart")

    if failures:
        print(f"open-webui-oidc-check: {len(failures)} problem(s)")
        return 1
    print("open-webui-oidc-check: blueprint, mount, app config and client all agree")
    return 0


if __name__ == "__main__":
    sys.exit(main())
