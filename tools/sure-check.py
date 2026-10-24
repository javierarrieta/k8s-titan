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

  1. apply/10-secrets/authentik-sure-blueprint.yaml   - the OIDC client authentik applies, including the
                                                       importer shape it must use: property_mappings
                                                       plural of scopemapping, !Find for cross-object
                                                       references, a signing key, and issuer_mode
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

ONBOARDING_STATE and SSO JIT are TWO INDEPENDENT DOORS and the gate checks both. ONBOARDING_STATE governs
only the local email+password registration page (registrations_controller.rb:119-121). SSO account
creation is governed by AUTH_JIT_MODE and ALLOWED_OIDC_DOMAINS (config/auth.yml, enforced at
oidc_accounts_controller.rb:24,119, which never reads onboarding_state). Closing the first while the
second can create accounts is closing the narrow door and leaving the wide one propped, and the only
thing bounding JIT is authentik's own enrolment policy. Each door is gated with an explicit
acknowledgement marker rather than a bare ban, so the permissive setting is always a reviewed statement
rather than a default that shipped.

THE HAND-WRITTEN HALF IS CHECKED TOO, because no chart renders it. REDIS_URL must name the `sure-redis`
Service this repo creates and must agree with the REDIS_PASSWORD that Service requires; sure-redis must
start with --requirepass and runAsNonRoot, since there is no NetworkPolicy in this tree and an open
Redis is a cluster-writable Sidekiq queue, which is an execution primitive. The two nested chart flags
that decide whether the chart computes its own DATABASE_URL/REDIS_URL must stay false; migrations
.strategy must be a value the chart actually acts on; and the chart version and the image tag must not
drift apart. Every one of these was a measured hole in the first version of this file: mutating the tree
in that way left the gate green.

Fixtures may be plaintext; real secrets are sops-encrypted. A file that looks encrypted but does not
decrypt is reported, never silently skipped.
"""
import argparse
import os
import re
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
# The marker that says "JIT can create accounts and the boundary is authentik enrolment, checked".
JIT_MARKER = "sure.titan.arrieta.eu/sso-jit-boundary"
# Reasoning models charge thinking tokens against max_tokens; measured on halogen-qwen3.8-flash-next,
# max_tokens=16 returned finish_reason=length with content:"" — a silent no-op in an auto-categorizer.
MIN_RESPONSE_TOKENS = 1024
PG_HOST = "postgres-rw.databases.svc.cluster.local"
# The Service this repo hand-writes in apply/50-apps/sure/sure.yaml. The chart computes no REDIS_URL
# here (redisSimple and redisOperator are both off), so nothing outside this file can see whether the
# URL in the Secret actually names it.
REDIS_HOST = "sure-redis"


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
            bp_doc = load_tolerating_tags(rendered) or {}
            # A blueprint with no `entries:` is a malformed blueprint, not a crash. A gate that raises
            # instead of reporting teaches the next reader to distrust the gate.
            bp_entries = bp_doc.get("entries") or []
            if not bp_entries:
                fail("the rendered blueprint has no `entries:` list - authentik imports nothing, and "
                     "a Secret whose key ends in .yaml but carries no entries is indistinguishable "
                     "from one that was never written")
            rprov = provider_of(bp_entries)
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

                # --- the shape authentik's importer actually accepts ---------------------------
                # All four of these were wrong in the first draft of this blueprint, and the version of
                # this gate that only checked presence, mount and redirect_uris passed every one of them.
                # The reasons live in the blueprint's own comments; what belongs here is the refusal.
                if "property_mapping" in rprov:
                    fail("the provider sets singular property_mapping. An oauth2provider takes "
                         "property_mappings (plural) of authentik_providers_oauth2.scopemapping; the LDAP "
                         "property-mapping model belongs to LDAP sources, and a provider that releases no "
                         "email claim breaks the JIT path that keys on auth.info.email")
                pms = rprov.get("property_mappings") or []
                if not pms:
                    fail("the provider has no property_mappings, so no scope is grantable and the id_token "
                         "carries no email")
                else:
                    joined = " ".join(str(p) for p in pms)
                    for need in ("scope-openid", "scope-email", "scope-profile"):
                        if need not in joined:
                            fail(f"property_mappings is missing {need}. Sure requests openid email profile "
                                 "(app/models/oidc/provider_options_builder.rb:5) and a scope with no "
                                 "mapping is a scope that cannot be granted")
                for field, why in (("signing_key",
                                    "without it authentik signs the id_token with HS256 using the "
                                    "client_secret (providers/oauth2/models.py:358-359) and the first real "
                                    "login dies at token verification while every pre-login check passes"),
                                   ("authorization_flow",
                                    "with no authorization flow authentik has no consent policy for the "
                                    "provider, and the failure appears at the redirect, not at apply"),
                                   ("invalidation_flow",
                                    "with no invalidation flow a Sure logout does not propagate back to "
                                    "authentik, so the session behind it survives")):
                    if not rprov.get(field):
                        fail(f"the provider has no {field}: {why}")
                if rprov.get("issuer_mode") != "per_provider":
                    fail(f"issuer_mode is {rprov.get('issuer_mode')!r}, not per_provider, while OIDC_ISSUER "
                         f"names the per-provider URL {ISSUER}. Slug and issuer are one decision in two "
                         "files; if they disagree the failure looks like a bad token")
                # `fk` resolves an `id:` inside the same blueprint (v1/importer.py:175-197, :441). Pointing
                # it at a cluster object passes YAML validation and fails the import with a UUID error.
                ids = {e.get("id") for e in bp_entries if e.get("id")}
                for m in re.finditer(r"(?m)^\s*fk:\s*(\S+)", rendered):
                    if m.group(1) not in ids:
                        fail(f"the blueprint uses fk: {m.group(1)}, resolvable only against an id: in the "
                             "same blueprint. Cross-object references must use !Find or !Get.")

        # --- one credential, two files ---------------------------------------------------------
        # authentik reads the client_secret from the blueprint, Sure from sure-secrets.yaml. Nothing
        # couples them, so a rotation that touches one produces a login that survives the redirect and
        # dies at the token exchange - the worst possible place for it, after every checkable step.
        bp_secret = (rprov or {}).get("client_secret")
        if bp_secret:
            sec_secret, _ = secret_key(docs, "sure-secrets", "sure", "OIDC_CLIENT_SECRET")
            if sec_secret is None:
                fail("sure-secrets.yaml has no OIDC_CLIENT_SECRET, so Sure has no client secret to "
                     "exchange with - the blueprint alone is not enough")
            elif sec_secret != bp_secret:
                fail("OIDC_CLIENT_SECRET in sure-secrets.yaml is not the client_secret in the blueprint. "
                     "They are the same credential and must move together")

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

        # Door 1: the local email+password registration page. ONBOARDING_STATE governs ONLY this
        # (registrations_controller.rb:119-121). It is not what governs SSO account creation.
        state = ((rails.get("settings") or {}).get("ONBOARDING_STATE") or "").strip().lower()
        marker = ((hr.get("metadata") or {}).get("annotations") or {}).get(ONBOARDING_MARKER)
        if state not in ("open", "closed", "invite_only", ""):
            fail(f"ONBOARDING_STATE is {state!r}. Sure accepts open | closed | invite_only (.env.example, "
                 "and docs/hosting/docker.md step 5a). A value it does not recognise is not a safe "
                 "default - it is whatever the app falls back to.")
        if state == "":
            fail("ONBOARDING_STATE is empty - the chart default is open, so an empty value is not a "
                 "safe default, it is the value that lets anyone register")
        if state == "open" and not marker:
            fail("ONBOARDING_STATE is open with no acknowledgement annotation. On a public hostname the "
                 "first visitor to /account/sign_up owns the instance. With OIDC configured there is no "
                 "reason to open it at all - the first account comes from SSO JIT instead. If this really "
                 f"is a one-reconcile window, add {ONBOARDING_MARKER} and delete it in the commit that "
                 "closes it.")
        if marker and state != "open":
            fail(f"the {ONBOARDING_MARKER} annotation is still present but ONBOARDING_STATE is "
                 f"{state!r} - the marker exists to mark an open window, and a stale one teaches the "
                 "next reader to ignore it")

        # Door 2: SSO account creation. Independent of door 1 - oidc_accounts_controller.rb:24,119 gates
        # on AuthConfig.jit_link_only? and allowed_oidc_domain?, and never reads onboarding_state. So
        # closing registration while JIT can create accounts has closed the narrow door and left the wide
        # one propped, and the only thing bounding JIT is authentik's own enrolment policy.
        jit = (env_named(values, "AUTH_JIT_MODE") or "create_and_link").strip().lower()
        domains = (env_named(values, "ALLOWED_OIDC_DOMAINS") or "").strip()
        jit_marker = ((hr.get("metadata") or {}).get("annotations") or {}).get(JIT_MARKER)
        if jit not in ("create_and_link", "link_only"):
            fail(f"AUTH_JIT_MODE is {jit!r}; Sure accepts create_and_link | link_only (config/auth.yml). "
                 "An unrecognised value falls back to create_and_link, the permissive one.")
        if jit == "create_and_link":
            if not domains:
                fail("ALLOWED_OIDC_DOMAINS is empty while JIT creates accounts. Empty is the permissive "
                     "value, not the strict one: AuthConfig.allowed_oidc_domain? returns true for every "
                     "address when the list is empty, so any authentik identity gets a Sure account.")
            if not jit_marker:
                fail(f"JIT creates accounts ({jit}) with no {JIT_MARKER} annotation. The real boundary is "
                     "authentik's enrolment policy, not the domain list. Evidence to re-check before "
                     "adding it: the Google source has no enrollment_flow by design "
                     "(authentik/blueprints-google.yaml:8,85), and /if/flow/default-registration-flow/ "
                     "measured 404 for anonymous visitors on 2026-10-23 while the authentication and "
                     "user-settings flows return 200. If either changes, the fix is "
                     "AUTH_JIT_MODE=link_only, not a wider allowlist.")
        if jit == "link_only" and state == "closed" and not jit_marker:
            fail("AUTH_JIT_MODE=link_only with ONBOARDING_STATE=closed means nothing can ever create an "
                 f"account from scratch. If users already exist that is intentional - say so with "
                 f"{JIT_MARKER} so the next reader can tell a locked door from a mistake.")
        if jit_marker and jit == "create_and_link" and not domains:
            fail(f"the {JIT_MARKER} annotation is present but ALLOWED_OIDC_DOMAINS is empty - the marker "
                 "asserts a reviewed boundary and an empty list asserts none")

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
            if not (wl.get("podAnnotations") or {}).get("reloader.stakater.com/auto"):
                fail(f"{workload}.podAnnotations has no reloader.stakater.com/auto - the chart exposes "
                     "no workload-metadata annotation, so this is the only place Reloader reads")

        # Subcharts that must stay off: titan already runs both operators.
        for key, why in (("cnpg", "titan already runs the CNPG operator and a shared Cluster, and "
                                 "Sure's data reaches the existing ScheduledBackup that way"),
                         ("redisOperator", "there is no Redis operator on titan"),
                         ("redisSimple", "its service name and password key are chart-derived")):
            if (values.get(key) or {}).get("enabled") is not False:
                fail(f"{key}.enabled is not false - {why}")

        # The two nested flags that actually decide whether the chart computes its own DATABASE_URL /
        # REDIS_URL (templates/_helpers.tpl: sure.databaseUrl, sure.redisUrl). Naming those keys in
        # rails.extraEnvVars does NOT suppress them - only a key in the rails.extraEnv MAP does, via
        # hasKey - so if one of these flips on, the chart emits a second DATABASE_URL plus a DB_PASSWORD
        # secretKeyRef aimed at a key sure-secrets does not have: CreateContainerConfigError, with the
        # pod never starting. Measured: deleting `cnpg.cluster.enabled: false` left the old gate green.
        for path, why in ((("cnpg", "cluster", "enabled"),
                           "the chart would compute a DATABASE_URL of its own and pair it with a "
                           "DB_PASSWORD key sure-secrets does not have"),
                          (("redisOperator", "managed", "enabled"),
                           "the chart would compute a REDIS_URL for a sentinel that is not installed")):
            node = values
            for part in path:
                node = (node or {}).get(part)
            if node is not False:
                fail(f"values.{'.'.join(path)} is not false - {why}")

        # The chart renders the hook Job only for strategy 'job' and the gating initContainer only for
        # 'initContainer'; anything else ships no migration step at all and stays silent about it.
        mig = (values.get("migrations") or {}).get("strategy")
        if mig not in ("job", "initContainer"):
            fail(f"migrations.strategy is {mig!r}. The chart accepts job or initContainer and renders "
                 "nothing for any other value, so the schema never moves and nothing reports it. Note "
                 "'job' is a post-install/post-upgrade hook (templates/migrate-job.yaml:9), not a "
                 "pre-upgrade one: the web pod rolls before the schema does.")

        # Chart version and image tag are the same upstream release pinned twice; a bump that moves one
        # and not the other is invisible to every other gate here.
        cver = (((hr.get("spec") or {}).get("chart") or {}).get("spec") or {}).get("version")
        tag = (values.get("image") or {}).get("tag")
        if cver and tag and str(cver) != str(tag):
            fail(f"spec.chart.spec.version is {cver!r} but values.image.tag is {tag!r} - they are one "
                 "upstream release pinned in two places. Drop the tag (the chart defaults it to "
                 "Chart.AppVersion) or move both together.")

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

        redis_url, _ = secret_key(docs, "sure-secrets", "sure", "REDIS_URL")
        redis_pw, _ = secret_key(docs, "sure-secrets", "sure", "REDIS_PASSWORD")
        if redis_url is None:
            fail("sure-secrets has no REDIS_URL - the chart computes none because both bundled Redis "
                 "paths are off, so the app would fall back to localhost and nothing would say so")
        else:
            r = urllib.parse.urlparse(redis_url)
            if r.hostname != REDIS_HOST:
                fail(f"REDIS_URL points at {r.hostname!r}, expected {REDIS_HOST!r} - the Service this "
                     "repo hand-writes in apply/50-apps/sure/sure.yaml. The chart computes nothing "
                     "here, so a wrong host is only ever visible as a worker crash-looping on a name "
                     "that does not resolve")
            if not (r.password or ""):
                fail("REDIS_URL carries no password while the redis container starts with "
                     "--requirepass - every connection is refused and the failure names Redis, not the "
                     "Secret")
            elif redis_pw is None:
                fail("sure-secrets has no REDIS_PASSWORD, which is the key the redis container reads "
                     "--requirepass from: Redis would start requiring an empty password while the app "
                     "presents whatever is in REDIS_URL")
            elif urllib.parse.unquote(r.password) != redis_pw:
                fail("REDIS_URL and REDIS_PASSWORD disagree - Redis requires one password and the app "
                     "presents the other. Rotate both together, they are one credential in two keys")

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
    # Parsed, not grepped. The previous version asked whether the text "\n        - sure" appeared, which
    # a rename to `- sure-not-real` satisfies; the Reflector half matched any line merely containing the
    # word sure, including a comment. Both were measured passing on a tree that was actually broken.
    hr_reloader = find(docs, "HelmRelease", "reloader", "apps")
    if hr_reloader is None:
        fail("no HelmRelease reloader/apps - cannot prove the reloader annotation is not inert")
    else:
        rvals = ((hr_reloader.get("spec") or {}).get("values") or {}).get("reloader") or {}
        if "sure" not in (rvals.get("namespaces") or []):
            fail("reloader.namespaces does not list `sure`. watchGlobally is false, so Reloader does not "
                 "look here at all and the pod annotation is inert - a rotated OIDC client or "
                 "SECRET_KEY_BASE sits unread in a running pod that reports Ready")

    cert = find(docs, "Certificate", "titan-wildcard", "certificates")
    if cert is None:
        fail("no Certificate titan-wildcard in namespace certificates - cannot prove titan-tls reaches "
             "namespace sure")
    else:
        anns = (((cert.get("spec") or {}).get("secretTemplate") or {}).get("annotations") or {})
        for ann in ("reflector.v1.k8s.emberstack.com/reflection-allowed-namespaces",
                    "reflector.v1.k8s.emberstack.com/reflection-auto-namespaces"):
            listed = [s.strip() for s in (anns.get(ann) or "").split(",") if s.strip()]
            if "sure" not in listed:
                fail(f"titan-wildcard secretTemplate annotation {ann} does not name `sure` exactly - the "
                     "Secret is never reflected into the namespace and the ingress has no certificate to "
                     "use")

    # --- the hand-written Redis: no chart renders it, so nothing else looks at it -------------------
    rdep = find(docs, "Deployment", "sure-redis", "sure")
    if rdep is None:
        fail("no Deployment sure-redis in namespace sure, while REDIS_URL points at that Service")
    else:
        rspec = ((rdep.get("spec") or {}).get("template") or {}).get("spec") or {}
        if not (rspec.get("securityContext") or {}).get("runAsNonRoot"):
            fail("sure-redis has no pod securityContext runAsNonRoot. The redis image config sets no "
                 "User at all, so the container runs as root; apply/60-tesla/redis.yaml:28-38 is the "
                 "file that records why naming the uid is the only thing that actually works")
        rargs = " ".join(str(a) for a in (((rspec.get("containers") or [{}])[0]).get("args") or []))
        if "--requirepass" not in rargs:
            fail("sure-redis starts without --requirepass. There is no NetworkPolicy anywhere in this "
                 "tree, so an open Redis is writable from every pod in the cluster, and a Sidekiq queue "
                 "anyone can enqueue to is an execution primitive that runs as Sure's own user against "
                 "Sure's own database")
        rymd = ((rdep.get("spec") or {}).get("template") or {})
        if not ((rymd.get("metadata") or {}).get("annotations") or {}).get("reloader.stakater.com/auto"):
            fail("sure-redis has no reloader.stakater.com/auto annotation. It reads REDIS_PASSWORD from "
                 "sure-secrets and so do web and worker through REDIS_URL, so if only the Rails pods "
                 "restart on a rotation Redis keeps requiring the old password while the app presents "
                 "the new one - one Secret, three readers, all three have to reload")

    if failures:
        print(f"sure-check: {len(failures)} problem(s)")
        return 1
    print("sure-check: blueprint, mount, OIDC client, DATABASE_URL and REDIS_URL, chart traps, the "
          "hand-written Redis, storage and the reloader/Reflector lists all agree")
    return 0


if __name__ == "__main__":
    sys.exit(main())
