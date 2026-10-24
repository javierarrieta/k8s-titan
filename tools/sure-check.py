#!/usr/bin/env python3
"""Fail if Sure's wiring has drifted apart — OIDC, the database, the chart's Secret trap, and the mount.

Sure is a HelmRelease, which is why this file exists rather than being folded into the existing gates.
Each of them is shape-bound and Sure falls between two of them:

  - `make db-url-check` walks a HelmRelease env named *PG_CONNECTION_URL (coder) or a Deployment's
    DATABASE_URL (open-webui). Sure is a HelmRelease carrying DATABASE_URL — neither shape — so it
    reports zero references and passes vacuously. Its own docstring names that as the one failure
    mode a reference-driven gate must never have.
  - `crd-check` walks vendored CRDs and `namespace-check` walks namespaces; neither looks inside a
    HelmRelease `values` block, which is where all of Sure's configuration actually lives.

So everything below is checked here, from the tree, offline.

Things that must agree:

  1. apply/10-secrets/authentik-sure-blueprint.yaml   - the OIDC client authentik applies
  2. apply/50-apps/auth/authentik.yaml               - the HelmRelease that has to mount it
  3. apply/50-apps/sure/sure.yaml                    - Sure's own copy of the client, its host, its
                                                       redirect URI, and every chart value that is a
                                                       trap if left at its default
  4. apply/10-secrets/sure-secrets.yaml              - Sure's DATABASE_URL and OIDC client
  5. apply/10-secrets/sure-db-credentials.yaml       - CNPG's copy of the same password
  6. apply/50-apps/sure/sure-db.yaml                 - the Database and DatabaseRole they both point at
  7. apply/20-infra/reloader/reloader.yaml           - the namespace list that makes the reloader
                                                       annotation mean anything
  8. apply/40-certificates/titan-wildcard.yaml       - the Reflector allow-list that delivers titan-tls

THE CHART TRAP THIS FILE WAS WRITTEN FOR. With `rails.existingSecret` set, chart sure 0.7.6-alpha.9
emits only SECRET_KEY_BASE and the three ACTIVE_RECORD_ENCRYPTION_* keys from that Secret. It lists
OPENAI_ACCESS_TOKEN, OIDC_CLIENT_ID, OIDC_CLIENT_SECRET and OIDC_ISSUER in rails.secret.values and then
does not wire them. Anything else the app needs from the Secret must be named in rails.extraEnvVars, or
the Secret has the key, the pod does not, and AI/SSO stay off at health=ok. Item 3 checks that.

ONBOARDING_STATE is checked with an explicit acknowledgement marker rather than a bare ban, because the
documented bring-up sequence (spec §5.1) genuinely needs it open for one reconcile: open, create the one
account, close. The marker makes that window a reviewed decision instead of a default.

Fixtures may be plaintext; real secrets are sops-encrypted. A file that looks encrypted but does not
decrypt is reported, never silently skipped.
"""
import argparse
import os
import sys
import urllib.parse

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from sopsload import find, load_docs, load_tolerating_tags, secret_key  # noqa: E402

HOST = "sure.titan.arrieta.eu"
# Strict, one entry. Sure's callback is OmniAuth's match "/auth/:provider/callback"
# (sure config/routes.rb:355) with the openid_connect strategy (config/initializers/omniauth.rb).
# Read from source, not measured live — if authentik ever reports a redirect_uri mismatch this is the
# value to correct, in the blueprint and in the HelmRelease together, and this gate is what forces both.
REDIRECTS = [f"https://{HOST}/auth/openid_connect/callback"]
ISSUER = f"https://auth.titan.arrieta.eu/application/o/sure/"
# The marker that says "yes, onboarding is open, and that is the reviewed one-reconcile window".
ONBOARDING_MARKER = "sure.titan.arrieta.eu/onboarding-window"
# Reasoning models charge thinking tokens against max_tokens; measured on halogen-qwen3.8-flash-next,
# max_tokens=16 returned finish_reason=length with content:"" — a silent no-op in an auto-categorizer.
MIN_RESPONSE_TOKENS = 1024
PG_HOST = "postgres-rw.databases.svc.cluster.local"


def provider_of(entries, name="sure"):
    for e in entries or []:
        if e.get("model", "").endswith("oauth2provider") and e.get("identifiers", {}).get("name") == name:
            return e.get("attrs", {})
    return None


def uri_urls(entry):
    """The url of one redirect_uris entry, whether written as a string or as {url, matching_mode}."""
    return entry.get("url") if isinstance(entry, dict) else entry


def env_named(values, name):
    """A plain `rails.extraEnv` value, or None."""
    return ((values.get("rails") or {}).get("extraEnv") or {}).get(name)


def envvar_names(values):
    return [e.get("name") for e in ((values.get("rails") or {}).get("extraEnvVars") or [])]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--root", default="apply", help="tree to scan (a fixture root for tests)")
    args = ap.parse_args()

    docs = load_docs(args.root)
    failures = []

    def fail(msg):
        failures.append(msg)
        print("FAIL:", msg)

    # --- 1 & 2: the blueprint and the mount ------------------------------------------------------
    # There is no separate reviewed template for Sure's blueprint the way mealie has one: the Secret
    # IS the reviewed artifact. That removes the template-vs-rendered drift mealie-check guards, and
    # makes the mount check the only thing standing between "committed" and "applied".
    bp = find(docs, "Secret", "authentik-sure-blueprint", "auth")
    rprov = None
    if bp is None:
        fail("no Secret authentik-sure-blueprint in namespace auth - the blueprint is not in the tree")
    else:
        rendered, _ = secret_key(docs, "authentik-sure-blueprint", "auth", "sure.yaml")
        if rendered is None:
            fail("Secret authentik-sure-blueprint has no key sure.yaml - the worker only picks up keys "
                 "ending in .yaml, and a valid blueprint with the wrong key name is invisible")
        else:
            rprov = provider_of(load_tolerating_tags(rendered)["entries"])
            if rprov is None:
                fail("the rendered blueprint has no oauth2provider named sure")
            else:
                if rprov.get("client_type") != "confidential":
                    fail("the OIDC provider is not client_type: confidential - Sure holds the client "
                         "secret server-side, so a public client type means the secret is decorative")
                uris = [uri_urls(u) for u in (rprov.get("redirect_uris") or [])]
                if sorted(uris) != sorted(REDIRECTS):
                    fail(f"blueprint redirect_uris are {uris}, expected {sorted(REDIRECTS)} - a "
                         "mismatch is refused by authentik and the error names authentik, not Sure")
                # authentik's redirect_uris is a list of {url, matching_mode}. A bare string is accepted
                # by YAML and by nothing that reads it, and the failure shows up as a login error.
                bad = [u for u in (rprov.get("redirect_uris") or []) if not isinstance(u, dict)]
                if bad:
                    fail(f"blueprint redirect_uris entries {bad} are bare strings, not "
                         "{{url:, matching_mode:}} mappings - authentik's model takes mappings")
                elif any((u.get("matching_mode") or "strict") != "strict"
                         for u in (rprov.get("redirect_uris") or [])):
                    fail("a redirect_uri is not matching_mode: strict - a prefix match is a redirect bypass")

    hr_auth = find(docs, "HelmRelease", "authentik", "auth")
    if hr_auth is None:
        fail("no HelmRelease authentik/auth")
    else:
        mounted = ((hr_auth["spec"].get("values").get("blueprints") or {}).get("secrets") or [])
        if "authentik-sure-blueprint" not in mounted:
            fail("the authentik HelmRelease does not mount authentik-sure-blueprint, so authentik never "
                 "reads it - mounting is not applying, but not mounting is definitely not applying")

    # --- 3: Sure's HelmRelease -------------------------------------------------------------------
    hr = find(docs, "HelmRelease", "sure", "sure")
    values = None
    if hr is None:
        fail("no HelmRelease sure/sure")
    else:
        values = hr["spec"].get("values") or {}
        rails = values.get("rails") or {}
        extra = envvar_names(values)

        # The chart trap, stated as a gate.
        if not rails.get("existingSecret"):
            fail("rails.existingSecret is unset - the chart would render the Secret from values, i.e. "
                 "plaintext credentials in git")
        else:
            sec = find(docs, "Secret", rails["existingSecret"], "sure")
            if sec is None:
                fail(f"rails.existingSecret names {rails['existingSecret']}, which is not in the tree")
            for key in ("OPENAI_ACCESS_TOKEN", "OIDC_CLIENT_ID", "OIDC_CLIENT_SECRET",
                        "DATABASE_URL", "REDIS_URL"):
                if key not in extra:
                    fail(f"rails.extraEnvVars does not name {key}. With existingSecret set the chart "
                         "wires only SECRET_KEY_BASE and the three ACTIVE_RECORD_ENCRYPTION_* keys, so "
                         "anything else in the Secret silently never reaches the pod")

        # OIDC: the issuer must be the per-provider one, and the redirect must match the blueprint.
        if env_named(values, "OIDC_ISSUER") != ISSUER:
            fail(f"OIDC_ISSUER is not {ISSUER} - it must name the per-provider issuer, which is what "
                 "issuer_mode: per_provider produces")
        red = env_named(values, "OIDC_REDIRECT_URI")
        if red not in REDIRECTS:
            fail(f"OIDC_REDIRECT_URI is {red!r}, expected one of {REDIRECTS}")
        if rprov is not None and red is not None and red not in [uri_urls(u) for u in (rprov.get("redirect_uris") or [])]:
            fail("OIDC_REDIRECT_URI is not among the blueprint's redirect_uris - authentik refuses the "
                 "authorization request and both services look healthy")

        # The onboarding window, as a reviewed decision rather than a default.
        state = ((rails.get("settings") or {}).get("ONBOARDING_STATE") or "").lower()
        marker = ((hr.get("metadata") or {}).get("annotations") or {}).get(ONBOARDING_MARKER)
        if state == "open" and not marker:
            fail("ONBOARDING_STATE is open with no acknowledgement annotation. On a public hostname the "
                 "first visitor to /account/sign_up owns the instance. Spec §5.1: open, create the one "
                 f"account, close. If that is the current step, add {ONBOARDING_MARKER}: \"open-until-"
                 "first-account\" and remove it in the commit that flips this to closed.")
        if state not in ("open", "closed", "invitations", "disabled", ""):
            fail(f"ONBOARDING_STATE is {state!r}, which is not a value Sure recognises")
        if marker and state != "open":
            fail(f"the {ONBOARDING_MARKER} annotation is still present but ONBOARDING_STATE is "
                 f"{state!r} - the marker exists to mark an open window, and a stale one teaches the "
                 "next reader to ignore it")

        # The LLM endpoint: /v1 must be in the base, and the reasoning budget must not be a footgun.
        base = env_named(values, "OPENAI_URI_BASE") or ""
        if not base.endswith("/v1"):
            fail(f"OPENAI_URI_BASE is {base!r} and does not end in /v1 - it is passed straight to "
                 "ruby-openai as uri_base (app/models/provider/openai.rb:85), so without the suffix "
                 "every call 404s")
        try:
            budget = int(env_named(values, "LLM_MAX_RESPONSE_TOKENS") or 0)
        except ValueError:
            budget = 0
        if budget < MIN_RESPONSE_TOKENS:
            fail(f"LLM_MAX_RESPONSE_TOKENS is {env_named(values, 'LLM_MAX_RESPONSE_TOKENS')!r}. The "
                 "configured model is a reasoning model and thinking tokens are charged against "
                 "max_tokens; too small a budget returns finish_reason=length with content empty, "
                 "which an auto-categorizer reads as 'nothing to do'")

        # Storage: mounted, at the path upstream uses, on both workloads.
        for workload in ("web", "worker"):
            wl = values.get(workload) or {}
            mounts = [(m.get("name"), m.get("mountPath")) for m in (wl.get("extraVolumeMounts") or [])]
            if ("/rails/storage" not in [m[1] for m in mounts]):
                fail(f"{workload}.extraVolumeMounts does not mount /rails/storage - uploads land in "
                     "the container's ephemeral filesystem and vanish on the next pod, and nothing "
                     "fails when that happens")
            if not wl.get("podAnnotations", {}).get("reloader.stakater.com/auto"):
                fail(f"{workload}.podAnnotations has no reloader.stakater.com/auto - the chart exposes "
                     "no workload-metadata annotation, so this is the only place Reloader reads")

        # Subcharts that must stay off: titan already runs both operators.
        for key, why in (("cnpg", "titan already runs the CNPG operator and a shared Cluster, and "
                                 "Sure's data reaches the existing ScheduledBackup that way"),
                         ("redisOperator", "there is no Redis operator on titan"),
                         ("redisSimple", "its service name and password key are chart-derived")):
            if (values.get(key) or {}).get("enabled") is not False:
                fail(f"{key}.enabled is not false - {why}")

        ing = values.get("ingress") or {}
        hosts = [h.get("host") for h in (ing.get("hosts") or [])]
        if hosts != [HOST]:
            fail(f"ingress serves {hosts}, expected ['{HOST}'] - the OIDC redirect URI and the wildcard "
                 "certificate both key off this host")
        tls_hosts = [h for b in (ing.get("tls") or []) for h in (b.get("hosts") or [])]
        if tls_hosts != [HOST]:
            fail("ingress.tls does not cover the host the app is served on")
        if not any(b.get("secretName") == "titan-tls" for b in (ing.get("tls") or [])):
            fail("ingress.tls does not use titan-tls, the reflected wildcard Secret")

    # --- 4 & 5: one password, two namespaces ------------------------------------------------------
    sec = find(docs, "Secret", "sure-secrets", "sure")
    db_url = None
    if sec is None:
        fail("no Secret sure-secrets in namespace sure")
    else:
        db_url, _ = secret_key(docs, "sure-secrets", "sure", "DATABASE_URL")
        if db_url is None:
            fail("sure-secrets has no DATABASE_URL")
        else:
            u = urllib.parse.urlparse(db_url)
            if u.hostname != PG_HOST:
                fail(f"DATABASE_URL points at {u.hostname!r}, expected {PG_HOST!r} - the read-write "
                     "service of the shared Cluster in namespace databases")
            if (u.path or "").lstrip("/") != "sure":
                fail(f"DATABASE_URL connects to database {(u.path or '').lstrip('/')!r}, expected 'sure'")
            dbsec = find(docs, "Secret", "sure-db-credentials", "databases")
            if dbsec is None:
                fail("no Secret sure-db-credentials in namespace databases - CNPG's DatabaseRole has no "
                     "credential to install")
            else:
                cnpg_pw, _ = secret_key(docs, "sure-db-credentials", "databases", "password")
                cnpg_user, _ = secret_key(docs, "sure-db-credentials", "databases", "username")
                if cnpg_pw is None:
                    fail("sure-db-credentials has no password key")
                elif cnpg_pw != (urllib.parse.unquote(u.password or "")):
                    fail("sure-secrets DATABASE_URL and sure-db-credentials disagree on the password - "
                         "Sure gets password authentication failed while the Database reports Ready. "
                         "Rotate both together; this is exactly what db-url-check cannot see here "
                         "because Sure is a HelmRelease, not a Deployment.")
                if cnpg_user is None:
                    fail("sure-db-credentials has no username key - CNPG's basic-auth Secret needs one "
                         "and it must equal the role name")
                elif cnpg_user != urllib.parse.unquote(u.username or ""):
                    fail(f"sure-db-credentials username {cnpg_user!r} is not the DATABASE_URL user "
                         f"{urllib.parse.unquote(u.username or '')!r}")

        for key, bp_key in (("OIDC_CLIENT_ID", "client_id"), ("OIDC_CLIENT_SECRET", "client_secret")):
            val, _ = secret_key(docs, "sure-secrets", "sure", key)
            if val is None:
                fail(f"sure-secrets has no {key}")
            elif rprov is not None and val != rprov.get(bp_key):
                fail(f"Sure's {key} does not match the blueprint's {bp_key} - login fails with "
                     "invalid_client while both files look fine")

    # --- 6: the CNPG side ------------------------------------------------------------------------
    db = find(docs, "Database", "sure", "databases")
    if db is None:
        fail("no Database sure in namespace databases")
    elif db.get("spec", {}).get("name") != "sure":
        fail(f"Database sure creates {db['spec'].get('name')!r}, not 'sure'")
    role = find(docs, "DatabaseRole", "sure", "databases")
    if role is None:
        fail("no DatabaseRole sure in namespace databases")
    else:
        if not role.get("spec", {}).get("login"):
            fail("DatabaseRole sure is not login: true - CNPG creates roles NOLOGIN by default, the "
                 "Database reports Ready and every connection fails pointing somewhere else")
        if (role.get("spec", {}).get("passwordSecret") or {}).get("name") != "sure-db-credentials":
            fail("DatabaseRole sure does not point at sure-db-credentials")

    # --- 7 & 8: the two lists that make an annotation and a certificate mean anything -------------
    reloader_path = os.path.join(args.root, "20-infra", "reloader", "reloader.yaml")
    if not os.path.exists(reloader_path):
        fail(f"no {reloader_path} - cannot prove the reloader annotation is not inert")
    else:
        text = open(reloader_path).read()
        if "\n        - sure" not in text:
            fail("reloader.yaml does not list the `sure` namespace. watchGlobally is false, so Reloader "
                 "does not look here at all and the pod annotation is inert - a rotated OIDC client or "
                 "SECRET_KEY_BASE sits unread in a running pod that reports Ready")

    cert_path = os.path.join(args.root, "40-certificates", "titan-wildcard.yaml")
    if not os.path.exists(cert_path):
        fail(f"no {cert_path} - cannot prove titan-tls reaches namespace sure")
    else:
        text = open(cert_path).read()
        for ann in ("reflection-allowed-namespaces", "reflection-auto-namespaces"):
            line = [l for l in text.splitlines() if ann in l]
            if not line or "sure" not in line[0]:
                fail(f"titan-wildcard.yaml {ann} does not include `sure` - the Secret is never "
                     "reflected into the namespace and the ingress has no certificate to use")

    if failures:
        print(f"sure-check: {len(failures)} problem(s)")
        return 1
    print("sure-check: blueprint, mount, OIDC client, DATABASE_URL, chart traps, storage and the "
          "reloader/Reflector lists all agree")
    return 0


if __name__ == "__main__":
    sys.exit(main())
