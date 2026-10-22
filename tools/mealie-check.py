#!/usr/bin/env python3
"""Fail if Mealie's wiring has drifted apart — OIDC, the database, and the mount.

Six things have to agree and nothing else ties them together:

  1. authentik/blueprints-mealie.yaml                       - the reviewed template, ${...} placeholders
  2. apply/10-secrets/authentik-mealie-blueprint.yaml       - the rendered artifact authentik applies
  3. apply/50-apps/mealie/mealie.yaml                       - the app's own copy of the client, and the
                                                             host Mealie builds its redirect URI from
  4. the HelmRelease actually mounting the blueprint
  5. apply/10-secrets/mealie-secrets.yaml                   - Mealie's POSTGRES_PASSWORD
  6. apply/10-secrets/mealie-db-credentials.yaml            - CNPG's copy of the same password

Item 4 is the failure this cluster has been burned by twice: docs/authentik-runbook.md §5 records a
blueprint that was committed, reviewed and green, and never mounted — indistinguishable from one never
written. Item 3 is coder's lesson (docs/coder-oidc-federation-runbook.md §4): two copies of one client
id, edited apart, and the login fails with invalid_client while both files look fine.

Items 5 and 6 are why this file exists at all rather than being folded into the OIDC checks.
`make db-url-check` is reference-driven and looks for a DATABASE_URL or PG_CONNECTION_URL; Mealie takes
POSTGRES_SERVER / POSTGRES_PORT / POSTGRES_DB / POSTGRES_USER / POSTGRES_PASSWORD instead, so the
generic gate never sees this app. The password is still duplicated across two namespaces, which is
exactly the split db-url-check was written to catch.

It also checks the settings whose DEFAULTS are traps, because each one produces a login that looks
healthy from the outside:

  - OIDC_REQUIRES_EMAIL_VERIFICATION defaults to true as of Mealie v3.21.0, and authentik's managed
    email scope mapping returns "email_verified": False (authentik/blueprints-coder.yaml). Left at the
    default, every authentik login is refused and the reason is only in Mealie's log.
  - BASE_URL is what Mealie builds its OIDC redirect URI from. If it stops matching the strict entries
    in the blueprint, authentik rejects the request and the error names authentik, not Mealie.
  - ALLOW_PASSWORD_LOGIN defaults to true, which leaves a local password door next to SSO — the Mealie
    equivalent of open-webui's ENABLE_LOGIN_FORM=false check.

Fixtures may be plaintext; real secrets are sops-encrypted. A file that looks encrypted but does not
decrypt is reported, never silently skipped.
"""
import argparse
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from sopsload import find, load_docs, load_tolerating_tags, secret_key  # noqa: E402

HOST = "meals.titan.arrieta.eu"
# Both documented URIs, each strict. Mealie derives the URI it sends from BASE_URL rather than from a
# configured callback, and its docs list both /login and /login?direct=1 (the second for RP-initiated
# logout, which authentik supports). A prefix match would be a redirect bypass, hence strict.
REDIRECTS = [f"https://{HOST}/login", f"https://{HOST}/login?direct=1"]
PLACEHOLDERS = ("${MEALIE_OIDC_CLIENT_ID}", "${MEALIE_OIDC_CLIENT_SECRET}")
ISSUER_URL = "https://auth.titan.arrieta.eu/application/o/mealie/.well-known/openid-configuration"


def provider_of(entries, name="mealie"):
    for e in entries or []:
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
                            "authentik", "blueprints-mealie.yaml")
    if not os.path.exists(tpl_path):
        fail(f"no reviewed template at {tpl_path}")
        tpl = None
    else:
        tpl = load_tolerating_tags(open(tpl_path).read())

    prov = provider_of(tpl["entries"]) if tpl else None
    if prov is None:
        fail("blueprints-mealie.yaml declares no oauth2provider named mealie")

    bp = find(docs, "Secret", "authentik-mealie-blueprint", "auth")
    if bp is None:
        fail("no Secret authentik-mealie-blueprint in namespace auth - the blueprint is not in the tree")
        rendered = None
    else:
        rendered, _ = secret_key(docs, "authentik-mealie-blueprint", "auth", "mealie.yaml")
        if rendered is None:
            fail("Secret authentik-mealie-blueprint has no key mealie.yaml - the worker only picks up "
                 "keys ending in .yaml")

    rprov = None
    if rendered is not None:
        rprov = provider_of(load_tolerating_tags(rendered)["entries"])
        if rprov is None:
            fail("the rendered blueprint has no oauth2provider named mealie")
        else:
            for ph in PLACEHOLDERS:
                if ph in rendered:
                    fail(f"the rendered blueprint still carries {ph} - it was committed before "
                         "scripts/setup-mealie-secrets.sh substituted it")
            if tpl is not None:
                # The rendered artifact must be the template with ONLY the two placeholders filled.
                want = open(tpl_path).read()
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
                     "`groups` claim Mealie's OIDC_ADMIN_GROUP reads will not be in the token")

    hr = find(docs, "HelmRelease", "authentik", "auth")
    if hr is None:
        fail("no HelmRelease authentik/auth")
    else:
        mounted = ((hr["spec"].get("values").get("blueprints") or {}).get("secrets") or [])
        if "authentik-mealie-blueprint" not in mounted:
            fail("the HelmRelease does not mount authentik-mealie-blueprint, so authentik never reads "
                 "it - mounting is not applying, but not mounting is definitely not applying")

    # --- Mealie's own copy -------------------------------------------------------------------
    dep = find(docs, "Deployment", "mealie", "mealie")
    if dep is None:
        fail("no Deployment mealie/mealie")
    else:
        if env_of(dep, "BASE_URL") != f"https://{HOST}":
            fail(f"BASE_URL is not https://{HOST} - Mealie builds its OIDC redirect URI from it, and a "
                 "mismatch is refused by authentik while both services look healthy")
        if env_of(dep, "OIDC_AUTH_ENABLED") != "true":
            fail("OIDC_AUTH_ENABLED is not true - Mealie would fall back to its own password table")
        if env_of(dep, "OIDC_CONFIGURATION_URL") != ISSUER_URL:
            fail(f"OIDC_CONFIGURATION_URL is not {ISSUER_URL} - it must name the per-provider issuer, "
                 "which is what issuer_mode: per_provider produces")
        if env_of(dep, "OIDC_REQUIRES_EMAIL_VERIFICATION") != "false":
            fail("OIDC_REQUIRES_EMAIL_VERIFICATION is not false. Mealie v3.21.0 defaults it to true and "
                 "authentik's managed email scope mapping returns \"email_verified\": False, so every "
                 "authentik login is refused. See authentik/blueprints-coder.yaml.")
        if env_of(dep, "ALLOW_PASSWORD_LOGIN") != "false":
            fail("ALLOW_PASSWORD_LOGIN is not false - a local password form next to SSO is a second, "
                 "unbacked door")
        if env_of(dep, "OIDC_ADMIN_GROUP") != "authentik Admins":
            fail("OIDC_ADMIN_GROUP is not 'authentik Admins' - it must name a group that exists in "
                 "authentik, or admins land in the ordinary-user seat silently")
        if env_of(dep, "DB_ENGINE") != "postgres":
            fail("DB_ENGINE is not postgres - Mealie would silently use sqlite on the PVC, which is not "
                 "backed up and is not what the Database/DatabaseRole in `databases` are for")

        names = [s.get("secretRef", {}).get("name")
                 for s in (dep["spec"]["template"]["spec"]["containers"][0].get("envFrom") or [])]
        sec_name = None
        for n in names:
            cand = find(docs, "Secret", n, "mealie")
            if cand is not None:
                for k in ("OIDC_CLIENT_ID", "OIDC_CLIENT_SECRET", "POSTGRES_PASSWORD"):
                    if (cand.get("stringData") or {}).get(k) is not None or (cand.get("data") or {}).get(k) is not None:
                        sec_name = n
        if sec_name is None:
            fail(f"no Secret reachable from mealie/mealie by envFrom carries OIDC_CLIENT_ID/"
                 f"OIDC_CLIENT_SECRET/POSTGRES_PASSWORD (envFrom names: {names})")
        else:
            for key, bp_key in (("OIDC_CLIENT_ID", "client_id"), ("OIDC_CLIENT_SECRET", "client_secret")):
                app_val, _ = secret_key(docs, sec_name, "mealie", key)
                if app_val is None:
                    fail(f"{sec_name} has no {key}")
                elif rprov and app_val != rprov.get(bp_key):
                    fail(f"Mealie's {key} does not match the blueprint's {bp_key} - the login will fail "
                         "with invalid_client, and the two files are edited apart")

            # The database half: one password, two namespaces, and no generic gate that sees it.
            pw, _ = secret_key(docs, sec_name, "mealie", "POSTGRES_PASSWORD")
            if pw is None:
                fail(f"{sec_name} has no POSTGRES_PASSWORD")
            dbsec = find(docs, "Secret", "mealie-db-credentials", "databases")
            if dbsec is None:
                fail("no Secret mealie-db-credentials in namespace databases - CNPG's DatabaseRole has "
                     "no credential to install")
            elif pw is not None:
                cnpg_pw, _ = secret_key(docs, "mealie-db-credentials", "databases", "password")
                cnpg_user, _ = secret_key(docs, "mealie-db-credentials", "databases", "username")
                if cnpg_pw is None:
                    fail("mealie-db-credentials has no password key")
                elif cnpg_pw != pw:
                    fail("mealie-secrets POSTGRES_PASSWORD and mealie-db-credentials password differ - "
                         "Mealie gets password authentication failed and the Database still reports "
                         "Ready. Re-run scripts/setup-mealie-secrets.sh with FORCE=1 and rotate both.")
                if cnpg_user is None:
                    fail("mealie-db-credentials has no username key - CNPG's basic-auth Secret needs one "
                         "and it must equal the role name")
                elif cnpg_user != env_of(dep, "POSTGRES_USER"):
                    fail(f"mealie-db-credentials username {cnpg_user!r} is not the Deployment's "
                         f"POSTGRES_USER {env_of(dep, 'POSTGRES_USER')!r}")

    ing = find(docs, "Ingress", "mealie", "mealie")
    if ing is None:
        fail("no Ingress mealie/mealie")
    else:
        # Why the Ingress gets its own structural check and the Deployment does not: a mis-nested
        # Ingress key is a CORE-type violation, and no offline gate here can see core types.
        # crd-check walks vendored CRDs only, namespace-check walks namespaces only, and
        # `make dry-run` — the one gate that asks the API server — needs an admin context this
        # identity does not have. On 2026-10-22 a comment block was written where `spec:` should
        # have been, `rules` landed under `metadata`, every offline gate stayed green, and the apps
        # stage went red on merge with "either defaultBackend or rules must be specified".
        leaked = sorted(k for k in ("rules", "tls", "ingressClassName", "defaultBackend")
                        if k in (ing.get("metadata") or {}))
        if leaked:
            fail(f"Ingress mealie/mealie carries {leaked} under metadata instead of spec - the API "
                 "server rejects it and no offline gate but make dry-run will tell you")
        spec = ing.get("spec") or {}
        hosts = [r.get("host") for r in (spec.get("rules") or [])]
        if hosts != [HOST]:
            fail(f"Ingress mealie/mealie serves {hosts}, expected ['{HOST}'] - BASE_URL, the blueprint "
                 "redirect URIs and the wildcard certificate all key off this host")
        if not spec.get("tls"):
            fail("Ingress mealie/mealie has no tls block - titan-tls has to terminate TLS for this host")

    db = find(docs, "Database", "mealie", "databases")
    if db is None:
        fail("no Database mealie in namespace databases")
    elif dep is not None and db.get("spec", {}).get("name") != env_of(dep, "POSTGRES_DB"):
        fail(f"Database mealie creates {db['spec'].get('name')!r} but the Deployment connects to "
             f"{env_of(dep, 'POSTGRES_DB')!r}")
    role = find(docs, "DatabaseRole", "mealie", "databases")
    if role is None:
        fail("no DatabaseRole mealie in namespace databases")
    else:
        if not role.get("spec", {}).get("login"):
            fail("DatabaseRole mealie is not login: true - CNPG creates roles NOLOGIN by default, the "
                 "Database reports Ready and every connection fails pointing somewhere else")
        if (role.get("spec", {}).get("passwordSecret") or {}).get("name") != "mealie-db-credentials":
            fail("DatabaseRole mealie does not point at mealie-db-credentials")

    if failures:
        print(f"mealie-check: {len(failures)} problem(s)")
        return 1
    print("mealie-check: blueprint, mount, app config, OIDC client and database credential all agree")
    return 0


if __name__ == "__main__":
    sys.exit(main())
