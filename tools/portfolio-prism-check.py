#!/usr/bin/env python3
"""Fail if Portfolio Prism's OIDC wiring has drifted apart.

Seven things have to agree and nothing else ties them together:

  1. authentik/blueprints-portfolio-prism.yaml                - the reviewed template, ${...} placeholders
  2. apply/10-secrets/authentik-portfolio-prism-blueprint.yaml - the rendered artifact authentik applies
  3. the HelmRelease mounting that blueprint into the worker
  4. apply/50-apps/portfolio-prism/portfolio-prism.yaml        - the app's own env: issuer, redirect,
                                                                 origins, and the address Rocket binds
  5. apply/10-secrets/portfolio-prism-secrets.yaml             - the app's own copy of the client pair
  6. the Ingress host, which every one of the above derives from
  7. the PVC's restic opt-in annotation, because the volume is one SQLite file holding the user's
     entire financial history

WHY THIS EXISTS AT ALL, AND WHY IT IS NOT FOLDED INTO <app>-oidc-check

On 2026-11-12 the app had never served a request, and every gate in this repo was green the whole time.
Two independent causes, both invisible offline until someone looked:

  - the blueprint identified its provider with `identifiers: slug: portfolio-prism`. OAuth2Provider has
    no `slug` field, so authentik rejected the ENTRY, which fails the whole BlueprintInstance, so
    nothing in the file ever applied - no provider, no application, no binding. The worker log shows
    `apply_blueprint` finishing in 51 ms with exc=null and then clear_failed_blueprints requeueing it
    forever; the reason exists only on the BlueprintInstance row. The only external symptom is
    /application/o/portfolio-prism/.well-known/openid-configuration answering 404 while coder, mealie,
    observability and sure answer 200 on the same host.
  - the deployment never set ROCKET_ADDRESS, so Rocket bound 127.0.0.1, every kubelet probe got
    `connect: connection refused`, the startup probe never passed, and the pod was never Ready. 1026
    restarts at exactly 5.0 minute intervals - the full 300 s probe budget - and the frontend access
    log over the container's whole life held 77,766 kube-probe lines and no other request.

Both are the same shape: a field that is absent or wrong in a file no existing gate reads. So this gate
asserts the identifier field by NAME (the check that would have caught cause 1), asserts the bind
address (cause 2), and asserts that the template and the rendered Secret have not been edited apart -
because landing the template without re-rendering the Secret fixes nothing while looking fixed.

Fixtures may be plaintext; real secrets are sops-encrypted. A file that looks encrypted but does not
decrypt is reported, never silently skipped.
"""
import argparse
import os
import re
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from sopsload import find, load_docs, load_tolerating_tags, secret_key  # noqa: E402

APP = "portfolio-prism"
HOST = "portfolio.titan.arrieta.eu"
ORIGIN = f"https://{HOST}"
# issuer_mode: per_provider builds the issuer from the provider's `name`, and the app compares its
# configured OIDC_ISSUER against the discovery document byte for byte - a missing trailing slash is a
# token-validation failure that looks like a bad signing key.
ISSUER_URL = f"https://auth.titan.arrieta.eu/application/o/{APP}/"
ISSUER_DISCOVERY = ISSUER_URL + ".well-known/openid-configuration"
REDIRECT = f"{ORIGIN}/auth/callback"
# The blueprint registers six: the production callback, two development callbacks (so a login can be
# tested without port-forwarding into the cluster), and the three logout callbacks the app always
# sends as post_logout_redirect_uri - derived as the ORIGIN of OIDC_REDIRECT_URI, no trailing slash.
# Anything beyond this set is unexplained, so it is a failure rather than a surprise.
ALLOWED_REDIRECTS = {
    REDIRECT, ORIGIN,
    "http://localhost:8000/auth/callback", "http://localhost:5173/auth/callback",
    "http://localhost:8000", "http://localhost:5173",
}
PLACEHOLDERS = ("${PORTFOLIO_OIDC_CLIENT_ID}", "${PORTFOLIO_OIDC_CLIENT_SECRET}")
BP_SECRET_NAME = "authentik-portfolio-prism-blueprint"
BP_KEY = "portfolio-prism.yaml"
APP_SECRET_NAME = "portfolio-prism-secrets"


def provider_of(entries, want=APP):
    """The oauth2provider entry, found by whichever identifier field it uses.

    Deliberately identifier-agnostic: a gate that only looks at `name` would have waved this file
    through while it was failing to apply, which is exactly what happened.
    """
    for e in entries or []:
        if e.get("model", "").endswith("oauth2provider"):
            return e
    return None


def attrs_of(entry):
    """The attrs block of a blueprint entry, or {}. `identifiers` and `attrs` are siblings; a check
    that reads `redirect_uris` off the entry itself silently reads nothing."""
    return (entry or {}).get("attrs") or {}


def application_of(entries, want=APP):
    for e in entries or []:
        if e.get("model", "").endswith("authentik_core.application") or \
           e.get("model", "").endswith("core.application"):
            return e
    return None


def identifier_problems(entry, where):
    """Problems with a provider entry's identifiers. Returns messages rather than printing them, so
    every finding reaches the caller's fail() and gets both printed and counted."""
    out = []
    if entry is None:
        return out
    ident = entry.get("identifiers") or {}
    if "slug" in ident:
        out.append(
            f"{where}: oauth2provider is identified by `slug: {ident['slug']}`. OAuth2Provider has no "
            "`slug` field - authentik rejects the entry with \"Cannot resolve keyword 'slug' into "
            "field\", which fails the WHOLE BlueprintInstance, so nothing in the file applies. The "
            "issuer path is built from the provider's `name`; identify on `name`.")
    elif ident.get("name") != APP:
        out.append(f"{where}: oauth2provider identifiers are {ident}, expected name: {APP} - "
                   "the issuer path /application/o/<name>/ is built from this value")
    return out


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

    # --- 1. the reviewed template -------------------------------------------------------------
    tpl_path = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
                            "authentik", "blueprints-portfolio-prism.yaml")
    tpl = None
    if not os.path.exists(tpl_path):
        fail(f"no reviewed template at {tpl_path}")
    else:
        tpl = load_tolerating_tags(open(tpl_path).read())
        for msg in identifier_problems(provider_of(tpl.get("entries")),
                                       "blueprints-portfolio-prism.yaml"):
            fail(msg)
        app_entry = application_of(tpl.get("entries"))
        if app_entry is None:
            fail("blueprints-portfolio-prism.yaml declares no authentik_core.application - the provider "
                 "exists but nothing links it to a launchable application")
        elif (app_entry.get("identifiers") or {}).get("slug") != APP:
            fail(f"the application entry is identified by {(app_entry.get('identifiers') or {})}, "
                 f"expected slug: {APP} - unlike the provider, Application DOES have a slug")

    # --- 2. the rendered artifact authentik actually applies -----------------------------------
    bp = find(docs, "Secret", BP_SECRET_NAME, "auth")
    rendered = None
    if bp is None:
        fail(f"no Secret {BP_SECRET_NAME} in namespace auth - the blueprint is not in the tree")
    else:
        rendered, _ = secret_key(docs, BP_SECRET_NAME, "auth", BP_KEY)
        if rendered is None:
            fail(f"Secret {BP_SECRET_NAME} has no key {BP_KEY} - the worker only picks up keys ending "
                 "in .yaml")

    rprov = None
    if rendered is not None:
        rprov = provider_of(load_tolerating_tags(rendered).get("entries"))
        attrs = attrs_of(rprov)
        for msg in identifier_problems(rprov, f"rendered {BP_SECRET_NAME}"):
            fail(msg)
        for ph in PLACEHOLDERS:
            if ph in rendered:
                fail(f"the rendered blueprint still carries {ph} - it was committed before the client "
                     "pair was substituted")
        if tpl is not None and rprov is not None:
            # The rendered artifact must be the template with ONLY the two placeholders filled. This is
            # the check that catches a template fix that never made it into the Secret - landing one
            # without the other fixes nothing while looking fixed.
            want = open(tpl_path).read()
            want = want.replace(PLACEHOLDERS[0], attrs.get("client_id") or "")
            want = want.replace(PLACEHOLDERS[1], attrs.get("client_secret") or "")
            if want != rendered:
                fail(f"the rendered blueprint is not the reviewed template plus the credentials - "
                     f"{tpl_path} and Secret {BP_SECRET_NAME} have been edited apart. Run "
                     f"scripts/rerender-authentik-blueprint.sh {APP}")
        entries = attrs.get("redirect_uris") or []
        urls = sorted(u.get("url") for u in entries)
        login = sorted(u.get("url") for u in entries
                       if (u.get("redirect_uri_type") or "login") != "logout")
        logout = sorted(u.get("url") for u in entries
                        if (u.get("redirect_uri_type") or "") == "logout")
        if REDIRECT not in login:
            fail(f"{REDIRECT} is not a login redirect_uri (have {login}) - a mismatch is refused by "
                 "authentik with an error the app never sees")
        if ORIGIN not in logout:
            fail(f"{ORIGIN} is not registered as a logout redirect_uri (have {logout}). The app always "
                 "sends post_logout_redirect_uri, derived as the origin of OIDC_REDIRECT_URI with no "
                 "trailing slash; unregistered, logout lands on an authentik error page instead of the "
                 "app.")
        extra = [u for u in urls if u not in ALLOWED_REDIRECTS]
        if extra:
            fail(f"unexpected redirect_uris {extra} - the reviewed set is the production callback, the "
                 f"two localhost dev callbacks, and their logout origins: {sorted(ALLOWED_REDIRECTS)}")
        if any((u.get("matching_mode") or "strict") != "strict" for u in entries):
            fail("a redirect_uri is not matching_mode: strict - a prefix match is a redirect bypass")
        if attrs.get("issuer_mode") != "per_provider":
            fail(f"issuer_mode is {attrs.get('issuer_mode')!r}, expected per_provider - the app's "
                 f"OIDC_ISSUER ({ISSUER_URL}) is the per-provider form and it compares byte for byte")
        if attrs.get("sub_mode") != "hashed_user_id":
            fail(f"sub_mode is {attrs.get('sub_mode')!r}. Changing it re-issues identity: the app keys a "
                 "user on (issuer, sub), so a new mode gives the same human a brand-new user row with "
                 "an empty portfolio and no admin surface to move the data back.")

    # --- 3. the mount --------------------------------------------------------------------------
    hr = find(docs, "HelmRelease", "authentik", "auth")
    if hr is None:
        fail("no HelmRelease authentik/auth")
    else:
        values = ((hr.get("spec") or {}).get("values") or {})
        mounted = ((values.get("blueprints") or {}).get("secrets") or [])
        if BP_SECRET_NAME not in mounted:
            fail(f"the HelmRelease does not mount {BP_SECRET_NAME}, so authentik never reads it - "
                 "a valid blueprint that is never mounted is indistinguishable from one never written")

    # --- 4. the app's own env ------------------------------------------------------------------
    dep = find(docs, "Deployment", APP, "apps")
    if dep is None:
        fail(f"no Deployment {APP}/apps")
    else:
        want_env = {
            "AUTH_MODE": "oidc",
            "OIDC_ISSUER": ISSUER_URL,
            "OIDC_REDIRECT_URI": REDIRECT,
            "ALLOWED_ORIGINS": ORIGIN,
            "DATABASE_URL": "sqlite:///app/data/portfolio.db?mode=rwc",
            # Rocket binds 127.0.0.1 without this, the kubelet probes from the node, and the pod never
            # becomes Ready. Upstream's own manifest omits it; the probes are upstream's too.
            "ROCKET_ADDRESS": "0.0.0.0",
        }
        for k, v in want_env.items():
            got = env_of(dep, k)
            if got != v:
                fail(f"{APP} env {k} is {got!r}, expected {v!r}")
        if env_of(dep, "BOOTSTRAP_OWNER_SUBJ") is not None:
            fail("BOOTSTRAP_OWNER_SUBJ is set. It is a ONE-WAY transfer with no admin undo and it "
                 "cannot be repeated; leaving it set means anyone who can present that sub can claim "
                 "whatever the placeholder still owns. Remove it once the handover has run.")
        for c in dep["spec"]["template"]["spec"]["containers"]:
            img = c.get("image", "")
            if "@sha256:" not in img:
                fail(f"{APP} container {c.get('name')} is not digest-pinned ({img!r}). The rollback "
                     "story for an auth change is `kubectl rollout undo`, which is a no-op on a tag "
                     "because the pod template is byte-identical.")
            if c.get("name") == "backend" and not c.get("startupProbe"):
                fail("the backend has no startupProbe. init_db runs a decimal migration, a duplicate-row "
                     "collapse and a unique index before Rocket binds the port; without a startup probe "
                     "the kubelet kills the container mid-migration and it restarts into the same work.")
        names = [s.get("secretRef", {}).get("name")
                 for c in dep["spec"]["template"]["spec"]["containers"]
                 for s in (c.get("envFrom") or [])]
        if APP_SECRET_NAME not in names:
            fail(f"the backend's envFrom does not reference {APP_SECRET_NAME} (names: {names})")

    # --- 5. the app's own copy of the client ----------------------------------------------------
    sec = find(docs, "Secret", APP_SECRET_NAME, "apps")
    if sec is None:
        fail(f"no Secret {APP_SECRET_NAME} in namespace apps")
    else:
        for key, bp_key in (("OIDC_CLIENT_ID", "client_id"), ("OIDC_CLIENT_SECRET", "client_secret")):
            app_val, _ = secret_key(docs, APP_SECRET_NAME, "apps", key)
            if app_val is None:
                fail(f"{APP_SECRET_NAME} has no {key}")
            elif rprov and app_val != attrs_of(rprov).get(bp_key):
                fail(f"{APP_SECRET_NAME} {key} does not match the blueprint's {bp_key} - sign-in fails "
                     "with authentik's \"client identifier is missing or invalid\" while both files "
                     "look fine. Re-render with scripts/rerender-authentik-blueprint.sh "
                     f"{APP} (it reuses the existing pair and mints nothing).")
        rk, _ = secret_key(docs, APP_SECRET_NAME, "apps", "ROCKET_SECRET_KEY")
        if rk is None:
            fail(f"{APP_SECRET_NAME} has no ROCKET_SECRET_KEY - Rocket refuses to launch without one, "
                 "and an ephemeral key would invalidate every session on the next restart")
        elif not re.fullmatch(r"[A-Za-z0-9+/=]{44}", rk):
            fail("ROCKET_SECRET_KEY is not 44 base64 characters (32 decoded bytes). Rocket 0.5 accepts "
                 "44 or 88 base64 chars or 64 hex; a shorter key does not fail quietly - the backend "
                 "refuses to launch. Use `openssl rand -base64 32`.")

    # --- 6. the host everything derives from ----------------------------------------------------
    ing = find(docs, "Ingress", APP, "apps")
    if ing is None:
        fail(f"no Ingress {APP}/apps")
    else:
        spec = ing.get("spec") or {}
        hosts = [r.get("host") for r in (spec.get("rules") or [])]
        if hosts != [HOST]:
            fail(f"Ingress {APP}/apps serves {hosts}, expected ['{HOST}'] - OIDC_REDIRECT_URI, "
                 "ALLOWED_ORIGINS and the wildcard certificate all key off this host")
        if not spec.get("tls"):
            fail(f"Ingress {APP}/apps has no tls block. The session cookie is Secure unconditionally, so "
                 "a cleartext path serves the SPA and every API call then 401s into a login loop.")

    # --- 7. the volume is the only copy of the user's financial history -------------------------
    pvc = find(docs, "PersistentVolumeClaim", f"{APP}-data", "apps")
    if pvc is None:
        fail(f"no PersistentVolumeClaim {APP}-data in namespace apps")
    else:
        ann = ((pvc.get("metadata") or {}).get("annotations") or {})
        if not ann.get("backup.titan.arrieta.eu/class"):
            fail(f"{APP}-data has no backup.titan.arrieta.eu/class annotation - local-path-retain is a "
                 "deletion mitigation, not a backup, and this volume is one SQLite file")

    if failures:
        print(f"portfolio-prism-check: {len(failures)} problem(s)")
        return 1
    print("portfolio-prism-check: blueprint identifiers, mount, rendered Secret, app env, client pair, "
          "host and backup annotation all agree")
    return 0


if __name__ == "__main__":
    sys.exit(main())
