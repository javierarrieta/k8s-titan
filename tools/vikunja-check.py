#!/usr/bin/env python3
"""Fail if Vikunja's wiring has drifted apart — OIDC, the database, the mail, and the mount.

Seven things have to agree and nothing else ties them together:

  1. authentik/blueprints-vikunja.yaml                     - the reviewed template, ${...} placeholders
  2. apply/10-secrets/authentik-vikunja-blueprint.yaml     - the rendered artifact authentik applies
  3. apply/50-apps/vikunja/vikunja.yaml                    - the app's own copy of the client, and the
                                                             host it builds its redirect URI from
  4. the authentik HelmRelease actually mounting the blueprint
  5. apply/10-secrets/vikunja-secrets.yaml                 - Vikunja's VIKUNJA_DATABASE_PASSWORD
  6. apply/10-secrets/vikunja-db-credentials.yaml          - CNPG's copy of the same password
  7. the mailer's FROM address and the mailbox it authenticates as

Item 4 is the failure this cluster has been burned by twice (docs/authentik-runbook.md §5): a blueprint
committed, reviewed and green, and never mounted — indistinguishable from one never written.

Items 5 and 6 are why this file exists at all rather than being folded into the OIDC checks.
`make db-url-check` is reference-driven and looks for a DATABASE_URL or a *PG_CONNECTION_URL; Vikunja
takes split VIKUNJA_DATABASE_* keys, so the generic gate reports zero references and passes vacuously
on this app. The password is still duplicated across two namespaces, which is exactly the split
db-url-check was written to catch. Sure's gate was written for the same gap from the other direction.

Item 7 is structural, not cosmetic: the relay runs SPOOF_PROTECTION=1, which restricts an authenticated
user to its own address and aliases. A FROM that does not match the mailbox is refused at MAIL FROM
while the pod reports healthy.

It also checks the settings whose ABSENCE is a silent failure:

  - VIKUNJA_SERVICE_SECRET. Unset, generateServiceSecretIfEmpty() in pkg/config/config.go mints a
    random one per boot, and every already-issued token dies with the process. With strategy: Recreate
    that is every deploy logging every session out, with no error anywhere.
  - VIKUNJA_AUTH_LOCAL_ENABLED. Defaults to true, which leaves a local password door beside SSO — the
    same call mealie's ALLOW_PASSWORD_LOGIN=false and open-webui's ENABLE_LOGIN_FORM=false record.
  - VIKUNJA_MAILER_ENABLED. Defaults to false, and reminders are already switched on behind it, so the
    mailer is the only switch and leaving it off is a silently decorative feature.
  - VIKUNJA_DATABASE_PORT must NOT be set. There is no database.port config key: pkg/db/db.go parses
    host:port out of database.host. A VIKUNJA_DATABASE_PORT is a dead variable that reads as
    configured — the mailserver runbook's `DNS_SERVER: unbound.apps` is the precedent for how
    expensive that shape is.

The dead-key and unknown-key sweeps cover the container's WHOLE environment: `env:` plus every key of
every Secret named by `envFrom`. That is what the pod actually receives. A typo'd key added to
vikunja-secrets — VIKUNJA_MAILER_FROMEAMIL, say — reaches the container as a dead variable in exactly
the shape this file exists to catch, and a sweep that walked `env:` alone reports clean on it. The
sweeps cannot see the opposite mistake either: `env:` beats `envFrom` in Kubernetes, so one of the
three Secret-owned keys pinned inline in `env:` silently overrides the real value, and the unknown-key
sweep passes it because those names are known by definition. That is asserted too.

Three facts are asserted on the blueprint body rather than on Vikunja's own copy, because the app's
copy cannot see them. The application's `slug` is what `issuer_mode: per_provider` turns into the
issuer URL, so comparing the Deployment's AUTHURL against ISSUER_URL proves nothing until something
pins the blueprint's slug to the slug ISSUER_URL is built from — move the slug and the live issuer
moves while the constant still matches. And the mode itself is pinned too, from the other side:
`issuer_mode` lives on the oauth2provider, not on the application, and it is authentik's own switch
for whether the slug appears in the issuer at all, so under the other value the issuer moves to a
slugless path while both the constant and the slug assertion still pass. Neither half catches the
other, and authentik builds the real issuer out of both. And the `titan-family` policybinding on that
application is the entire authorization story for this host: it is in NOT_PROXY_GATED, so there is no
forwardAuth in front of it, VIKUNJA_AUTH_LOCAL_ENABLED=false closes the local-password door and
registration is off, so who may sign in at all is exactly the set of groups bound to that application.
`blueprint-mount-check` cannot cover it: it only proves that a *present* binding names a declared
group, absence is not a failure there, and it never reads the rendered Secret.

There is deliberately NO email_verified check here, which will read as an omission to anyone who has
seen coder or mealie. Vikunja keys identity on (issuer, sub) and reads email_verified only in the
deprecated emailfallback path that auth.local.enabled=false makes unreachable. Spec D6 has the source
evidence. If a future Vikunja changes that, the fix is a check here, not a guess in the manifest.

Fixtures may be plaintext; real secrets are sops-encrypted. A file that looks encrypted but does not
decrypt is reported, never silently skipped.

Nothing here prints a secret value or a line of a blueprint body. That rules out the obvious way to
report an unparseable blueprint: a YAML error quotes the offending source line, and a blueprint line
is exactly where a client_secret lives, so an unparseable blueprint is named by file or by Secret key
and the parser's own message is dropped. The only values echoed out of a parsed blueprint are the
non-credentials an assertion is specifically about — the redirect URI list, the admission group names,
the policy engine mode — and never the client credential fields.

Malformed input is a FAIL: line wherever an element can be absorbed. Every field this file reads out
of a manifest or a blueprint may be absent, null, or the wrong type, and a gate that dies is a gate
that gets skipped; the helpers below absorb an absent, null or wrong-typed *element* and the
assertions still run on what comes back. A wrong-typed *container* — `tls: 5`, `redirect_uris: 5`,
`property_mappings: 5` — may still raise: absorbing those means inventing a meaning for a scalar tls
block, and no such manifest survives the API server, so `make dry-run` owns that class. The one
container fixed here instead is a `Database` with no `spec`, because a mis-indented `name:` under
`metadata` produces exactly that shape and this gate runs before `crd-check` in `make check`, so a
traceback here masks the gate that would have named the cause.
"""
import argparse
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from sopsload import find, load_docs, load_tolerating_tags, secret_key  # noqa: E402

import yaml  # noqa: E402

HOST = "tasks.titan.arrieta.eu"
PROVIDER = "authentik"
# /auth/openid/<provider-id>. The provider id is the YAML key Vikunja is configured under, which is
# the env-var segment lowercased — setConfigFromEnv() splits on "_" and lowercases every segment.
REDIRECT = f"https://{HOST}/auth/openid/{PROVIDER}"
# The application slug, and the issuer it produces. Under `issuer_mode: per_provider` authentik
# publishes the issuer at /application/o/<slug>/, so this constant and the blueprint's slug are one
# fact: ISSUER_URL is BUILT from APP_SLUG so that the AUTHURL comparison below and the blueprint slug
# assertion below cannot drift apart, and the assertions on slug AND mode are what tie both to the
# real object. ISSUER_MODE is asserted alongside it because the constant is the live issuer only while
# BOTH hold, and the mode is not on this object: authentik's Provider model owns `issuer_mode`, so the
# blueprint carries it on the oauth2provider entry and the assertion reads it there. Authentik's own
# default is `default`, which publishes the issuer at the slugless /application/o/ and would leave
# APP_SLUG, ISSUER_URL and the slug assertion all still matching a URL nothing serves.
APP_SLUG = "vikunja"
ISSUER_MODE = "per_provider"
ISSUER_URL = f"https://auth.titan.arrieta.eu/application/o/{APP_SLUG}/"
# The reviewed admission set, in the gate rather than read from the blueprint: a decision about who may
# reach a public host with no proxy-side gate has to be written down twice to be reviewed twice.
GROUPS = ("titan-family",)
POLICY_ENGINE_MODE = "any"
APP_MODEL = "authentik_core.application"
BINDING_MODEL = "authentik_policies.policybinding"
GROUP_MODEL = "authentik_core.group"
# The two placeholders scripts/setup-vikunja-secrets.sh fills, each paired with the provider attribute
# it stands for. Both the leftover-placeholder check and the byte-rebuild below are driven off this one
# tuple, so adding a third placeholder cannot leave one of the two checks behind.
PLACEHOLDERS = (("${VIKUNJA_OIDC_CLIENT_ID}", "client_id"),
                ("${VIKUNJA_OIDC_CLIENT_SECRET}", "client_secret"))
PREFIX = "VIKUNJA_AUTH_OPENID_PROVIDERS_AUTHENTIK_"
# Config keys that exist, so a VIKUNJA_* env var naming nothing is caught rather than ignored.
# Trimmed to what this app sets; extend it when a new key is introduced, do not let it rot.
KNOWN_KEYS = {
    "VIKUNJA_SERVICE_PUBLICURL", "VIKUNJA_SERVICE_SECRET", "VIKUNJA_SERVICE_ENABLEREGISTRATION",
    "VIKUNJA_SERVICE_TIMEZONE", "VIKUNJA_SERVICE_IPEXTRACTIONMETHOD", "VIKUNJA_SERVICE_TRUSTEDPROXIES",
    "VIKUNJA_SENTRY_ENABLED", "VIKUNJA_AUTH_LOCAL_ENABLED", "VIKUNJA_AUTH_OPENID_ENABLED",
    "VIKUNJA_AUTH_OPENID_PROVIDERS_AUTHENTIK_NAME", "VIKUNJA_AUTH_OPENID_PROVIDERS_AUTHENTIK_AUTHURL",
    "VIKUNJA_AUTH_OPENID_PROVIDERS_AUTHENTIK_SCOPE", "VIKUNJA_AUTH_OPENID_PROVIDERS_AUTHENTIK_LOGOUTURL",
    "VIKUNJA_AUTH_OPENID_PROVIDERS_AUTHENTIK_CLIENTID",
    "VIKUNJA_AUTH_OPENID_PROVIDERS_AUTHENTIK_CLIENTSECRET",
    "VIKUNJA_DATABASE_TYPE", "VIKUNJA_DATABASE_HOST", "VIKUNJA_DATABASE_DATABASE",
    "VIKUNJA_DATABASE_USER", "VIKUNJA_DATABASE_PASSWORD", "VIKUNJA_DATABASE_MAXOPENCONNECTIONS",
    "VIKUNJA_DATABASE_MAXIDLECONNECTIONS", "VIKUNJA_FILES_BASEPATH",
    "VIKUNJA_MAILER_ENABLED", "VIKUNJA_MAILER_HOST", "VIKUNJA_MAILER_PORT", "VIKUNJA_MAILER_FORCESSL",
    "VIKUNJA_MAILER_FROMEMAIL", "VIKUNJA_MAILER_USERNAME", "VIKUNJA_MAILER_PASSWORD",
}
DEAD_KEYS = {"VIKUNJA_DATABASE_PORT"}


def provider_of(entries, name="vikunja"):
    for e in entries or []:
        if e.get("model", "").endswith("oauth2provider") and e.get("identifiers", {}).get("name") == name:
            return e.get("attrs", {})
    return None


def find_value(tag, model, key):
    """Value of a rebuilt `!Find [model, [key, value]]` tag, or None if this is not that shape.

    `load_tolerating_tags` turns an authentik tag into a plain list — `["!Find", model, [key, val]]`
    — because PyYAML's safe loader rejects the tag outright. Matching the rebuilt structure rather
    than the raw text is what stops this passing when someone writes the same lookup with the
    arguments swapped or the inner pair flattened. Same helper, same shape, as grafana-oidc-check's.
    """
    if not (isinstance(tag, list) and len(tag) == 3 and tag[0] == "!Find"):
        return None
    if tag[1] != model or not isinstance(tag[2], list) or len(tag[2]) != 2 or tag[2][0] != key:
        return None
    return tag[2][1]


def keyof(value):
    """The name inside a rebuilt `!KeyOf NAME`, or None."""
    if isinstance(value, str) and value.startswith("!KeyOf "):
        return value.split(None, 1)[1].strip()
    return None


def app_of(entries):
    """The blueprint's `authentik_core.application` entry, or None.

    Returns the ENTRY, not its attrs, because the caller needs `id` to recognise a `!KeyOf` reference
    to it from a binding. This blueprint declares exactly one application, so matching on the model
    is enough; the slug is then asserted rather than used to find the entry, which is the whole point
    — a renamed slug must fail loudly, not be quietly followed.
    """
    for e in entries or []:
        if e.get("model") == APP_MODEL:
            return e
    return None


def bindings_for(entries, app_id, slug):
    """The policybinding entries that target the application, in either reference form.

    A binding names its target as `!KeyOf <local id>` when the target is declared in the same
    blueprint with an `id`, or as `!Find [authentik_core.application, [slug, …]]` when it is looked
    up. Matching only one form means rewriting the other silently detaches the binding from the
    application it was gating — and a detached binding still looks like a binding in the file.

    `app_id` is guarded rather than compared bare: a missing `id` yields None, and `keyof()` returning
    None for a target that is not a recognised shape would otherwise match it and pull in every
    binding in the blueprint.
    """
    out = []
    for e in entries or []:
        if e.get("model") != BINDING_MODEL:
            continue
        target = (e.get("identifiers") or {}).get("target")
        if find_value(target, APP_MODEL, "slug") == slug:
            out.append(e)
        elif app_id is not None and keyof(target) == app_id:
            out.append(e)
    return out


def entries_of(body):
    """The top-level `entries` of a parsed blueprint body, or None.

    A blueprint that parses to a mapping without `entries` — or to a scalar, or to a list — is
    malformed, not a crash. Indexing it would raise KeyError/TypeError and print a traceback where a
    FAIL: line belongs, and a gate that fails a correct tree gets worked around instead of fixed.
    """
    return body.get("entries") if isinstance(body, dict) else None


def redirect_uris_of(provider):
    """[(url, matching_mode)] for a provider's redirect_uris.

    authentik accepts each entry as either a mapping ({url, matching_mode}) or a bare string, and a
    bare string takes the default matching_mode of strict. Reading `.url` off every entry would raise
    AttributeError on the shorter form — again, a traceback where a FAIL: line belongs.

    An entry that declares no url yields the placeholder `<unset>` rather than None, and an entry that
    is neither a mapping nor a string yields the same. Both keep the caller's `sorted` over strings:
    one None among the URIs is a TypeError in the sort, which is a crash on a blueprint the gate is
    supposed to be reporting on. The placeholder still fails the comparison against the one URI this
    gate demands, so absorbing the shape is not the same as accepting it.
    """
    out = []
    for u in provider.get("redirect_uris") or []:
        if isinstance(u, str):
            out.append((u, "strict"))
        elif isinstance(u, dict):
            out.append((u.get("url") or "<unset>", u.get("matching_mode") or "strict"))
        else:
            out.append(("<unset>", "strict"))
    return out


def tls_secret_names_of(ing_spec):
    """The Secret name each `tls` entry asks for, `<unset>` where it names none. Sorted and unique.

    The same shape problem as redirect_uris_of, one object type later: a tls entry is a mapping in a
    correct manifest, but `.get` off a bare string or a scalar is an AttributeError where a FAIL:
    belongs. A string is read as the name it stands for and anything else as `<unset>`, so a malformed
    entry still reaches the assertion instead of vanishing from it. Whether a tls entry is *shaped*
    correctly is a core-type question and belongs to `make dry-run`, as the comment at the call site
    already says; what this gate owns is which Secret the Ingress asks for.
    """
    names = []
    for t in ing_spec.get("tls") or []:
        if isinstance(t, str):
            names.append(t)
        elif isinstance(t, dict):
            names.append(t.get("secretName") or "<unset>")
        else:
            names.append("<unset>")
    return sorted(set(names))


def containers_of(dep):
    return (((dep.get("spec") or {}).get("template") or {}).get("spec") or {}).get("containers") or []


def env_of(deploy, name):
    for c in containers_of(deploy):
        for env in c.get("env") or []:
            if env.get("name") == name:
                return env.get("value")
    return None


def all_env_names(dep):
    names = set()
    for c in containers_of(dep):
        for env in c.get("env") or []:
            names.add(env.get("name"))
    return names


def env_from_names(dep):
    """Every Secret name the pod's environment comes from, across every container.

    Same scope as env_of and all_env_names, which walk every container: reading envFrom off
    containers[0] alone would miss a Secret attached to a second container.
    """
    names = []
    for c in containers_of(dep):
        for ref in c.get("envFrom") or []:
            n = (ref.get("secretRef") or {}).get("name")
            if n:
                names.append(n)
    return names


def secret_keys_of(docs, name, namespace):
    """Every key in a Secret — the whole map secret_key() returns second, decoded if it is `data:`."""
    return secret_key(docs, name, namespace, "")[1] or {}


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
                            "authentik", "blueprints-vikunja.yaml")
    tpl_text = None
    tpl = None
    if not os.path.exists(tpl_path):
        fail(f"no reviewed template at {tpl_path}")
    else:
        with open(tpl_path) as fh:
            tpl_text = fh.read()
        try:
            tpl = load_tolerating_tags(tpl_text)
        except yaml.YAMLError as exc:
            # The template lives outside --root, so load_docs' own YAML guard never saw it. The
            # parser's message is named by class only: it quotes the offending line and this file
            # never prints blueprint text.
            fail(f"{tpl_path} is not valid YAML ({type(exc).__name__}) - the reviewed template cannot "
                 "be read, so nothing below it can be compared")

    tpl_entries = entries_of(tpl)
    prov = provider_of(tpl_entries)
    if prov is None:
        fail("blueprints-vikunja.yaml declares no oauth2provider named vikunja")
    else:
        # The issuer the Deployment is configured with is built from TWO entries: the application's
        # `slug` (asserted below, in the application block) and this provider's `issuer_mode`. Both are
        # needed and neither catches the other, so both are asserted — here and there, each on the object
        # that actually carries it, because authentik's Provider model owns `issuer_mode` and the
        # application model owns `slug`. Flip the mode to authentik's own default (`default`) and the
        # issuer moves to the slugless /application/o/ while APP_SLUG, ISSUER_URL and the slug assertion
        # all stay exactly as they were, so the AUTHURL comparison keeps matching a URL nothing serves.
        # Echoed rather than withheld: it is a small enum, and which value it became is the diagnostic.
        if prov.get("issuer_mode") != ISSUER_MODE:
            fail(f"blueprints-vikunja.yaml's vikunja provider issuer_mode is "
                 f"{prov.get('issuer_mode')!r}, expected {ISSUER_MODE!r}. This mode is what puts the "
                 f"issuer at {ISSUER_URL}; changing it moves the issuer the Deployment is configured "
                 f"with ({PREFIX}AUTHURL) while the application's slug assertion and the {ISSUER_URL} "
                 "constant both still pass. Every login then fails on a token whose `iss` Vikunja never "
                 "configured, and the error names neither file. Move the mode and this constant "
                 "together, or leave the mode alone.")

    # --- the application, and who is admitted to it ----------------------------------------------
    # Both of these are on the reviewed template, which is the artifact a human edits and the one that
    # wins the argument with the generated Secret (the byte-rebuild below is what makes the rendered
    # artifact obey it). Neither was read at all before the whole-branch review. The third blueprint fact,
    # `issuer_mode`, is asserted just above, on the entry that carries it.
    app = app_of(tpl_entries)
    if app is None:
        fail("blueprints-vikunja.yaml declares no authentik_core.application entry - the application is "
             "what fixes the issuer under issuer_mode: per_provider and what the admission binding "
             "attaches to, so with none in the blueprint neither of those can be checked")
    else:
        app_attrs = app.get("attrs") or {}
        if app_attrs.get("slug") != APP_SLUG:
            # Deliberately not echoing the value found: the slug is not a secret, but the file is one
            # `git diff` away and the message is already unambiguous about which field moved.
            fail(f"blueprints-vikunja.yaml's application slug is not {APP_SLUG!r}. Under "
                 "issuer_mode: per_provider the slug IS the issuer path, so the issuer authentik "
                 f"publishes no longer matches the {ISSUER_URL} the Deployment is configured with: "
                 "every login fails on a token from an issuer Vikunja never configured, and the error "
                 "names neither file. Move the slug and this constant together, or leave the slug alone.")
        # The other half of this fact — `issuer_mode` — is asserted above, on the oauth2provider that
        # carries it. Read the two together.
        # The whole authorization story, in the literal sense: this host is in NOT_PROXY_GATED, so no
        # forwardAuth refuses anyone first, VIKUNJA_AUTH_LOCAL_ENABLED=false closes the local-password
        # door and registration is off. Whoever this binding names is who may sign in.
        #
        # Exact set equality, not "at least one": dropping a binding and adding one both change who
        # gets in, and both read as a perfectly healthy login page.
        bindings = bindings_for(tpl_entries, app.get("id"), APP_SLUG)
        groups = sorted({g for e in bindings
                         for g in [find_value((e.get("attrs") or {}).get("group"),
                                              GROUP_MODEL, "name")]
                         if g})
        if not bindings:
            fail(f"blueprints-vikunja.yaml binds no policy to the {APP_SLUG} application. With no "
                 "binding authentik's policy engine admits every authenticated account, and this host "
                 "has no proxy-side gate, no local password and no registration to refuse anyone first - "
                 "this binding is the entire authorization decision for a public internet-facing host.")
        elif groups != sorted(GROUPS):
            fail(f"blueprints-vikunja.yaml binds the {APP_SLUG} application to {groups}, expected "
                 f"exactly {sorted(GROUPS)} - missing {sorted(set(GROUPS) - set(groups))}, extra "
                 f"{sorted(set(groups) - set(GROUPS))}. Either direction changes who may sign in on a "
                 "host with no other gate in front of it. If the change was deliberate, change GROUPS "
                 "in this script in the same commit so the decision is reviewed twice.")
        mode = app_attrs.get("policy_engine_mode")
        if mode != POLICY_ENGINE_MODE:
            fail(f"the {APP_SLUG} application's policy_engine_mode is {mode!r}, expected "
                 f"{POLICY_ENGINE_MODE!r}. These bindings are a union only under `any`; under `all` the "
                 "same rows demand membership of every group at once and lock out everyone the set was "
                 "written to admit.")

    bp = find(docs, "Secret", "authentik-vikunja-blueprint", "auth")
    if bp is None:
        fail("no Secret authentik-vikunja-blueprint in namespace auth - the blueprint is not in the tree")
        rendered = None
    else:
        rendered, _ = secret_key(docs, "authentik-vikunja-blueprint", "auth", "vikunja.yaml")
        if rendered is None:
            fail("Secret authentik-vikunja-blueprint has no key vikunja.yaml - the worker only picks "
                 "up keys ending in .yaml")

    rprov = None
    if rendered is not None:
        try:
            body = load_tolerating_tags(rendered)
        except yaml.YAMLError as exc:
            # The body is a string *inside* a Secret, so load_docs parsing the Secret says nothing
            # about parsing this. Same rule as the template: name the key, never the body.
            fail("the vikunja.yaml key of Secret auth/authentik-vikunja-blueprint is not valid YAML "
                 f"({type(exc).__name__}) - the blueprint body cannot be read, so nothing in it can be "
                 "compared")
            body = None
        rprov = provider_of(entries_of(body))
        if rprov is None:
            fail("the rendered blueprint has no oauth2provider named vikunja")
        else:
            for ph, _attr in PLACEHOLDERS:
                if ph in rendered:
                    fail(f"the rendered blueprint still carries {ph} - it was committed before "
                         "scripts/setup-vikunja-secrets.sh substituted it")
            if tpl_text is not None:
                # The rendered artifact must be the template with ONLY the two placeholders filled.
                # Anything else means someone edited one file and not the other, and the template is
                # the reviewed artifact — the Secret is generated, so the template wins the argument.
                want = tpl_text
                for ph, attr in PLACEHOLDERS:
                    want = want.replace(ph, rprov.get(attr) or "")
                if want != rendered:
                    fail("the rendered blueprint is not the reviewed template plus the credentials - "
                         "someone edited one file and not the other")
            uris = sorted(url for url, _mode in redirect_uris_of(rprov))
            if uris != [REDIRECT]:
                fail(f"redirect_uris are {uris}, expected ['{REDIRECT}'] - the path is "
                     "/auth/openid/<provider-id> and the provider id is the env-var segment lowercased")
            if any(mode != "strict" for _url, mode in redirect_uris_of(rprov)):
                fail("a redirect_uri is not matching_mode: strict - a prefix match is a redirect bypass")
            mappings = " ".join(str(m) for m in (rprov.get("property_mappings") or []))
            if "scope-openid" not in mappings:
                fail("the provider's property_mappings do not include the openid scope. Without it the "
                     "ID token carries no `sub`, and getOrCreateUser() looks a user up by "
                     "(issuer, sub) and nothing else, so every login fails or mints a stranger")
            if "scope-profile" not in mappings:
                fail("the provider's property_mappings do not include the profile scope, so "
                     "preferred_username is not in the token and Vikunja mints a pet-name username "
                     "for every user while the login succeeds")
            if "scope-email" not in mappings:
                fail("the provider's property_mappings do not include the email scope. mergeClaims() "
                     "returns ErrNoOpenIDEmailProvided when there is no email claim, so this is a "
                     "refused login, not a cosmetic gap")
            if "groups" in mappings:
                fail("the provider carries a groups scope. From Vikunja 2.8.0 that switches on team "
                     "sync, where every group name becomes a Vikunja team (spec D20). If that is now "
                     "wanted, update the spec as well as this gate.")

    hr = find(docs, "HelmRelease", "authentik", "auth")
    if hr is None:
        fail("no HelmRelease authentik/auth")
    else:
        values = ((hr.get("spec") or {}).get("values") or {})
        mounted = ((values.get("blueprints") or {}).get("secrets") or [])
        if "authentik-vikunja-blueprint" not in mounted:
            fail("the HelmRelease does not mount authentik-vikunja-blueprint, so authentik never reads "
                 "it - mounting is not applying, but not mounting is definitely not applying")

    # --- Vikunja's own copy -------------------------------------------------------------------
    dep = find(docs, "Deployment", "vikunja", "vikunja")
    if dep is None:
        fail("no Deployment vikunja/vikunja")
    else:
        # PUBLICURL is what Vikunja builds its own redirect URI from, so it and the blueprint URI are
        # one fact. A mismatch is refused by authentik and the error names authentik, not Vikunja.
        if env_of(dep, "VIKUNJA_SERVICE_PUBLICURL") not in (f"https://{HOST}", f"https://{HOST}/"):
            fail(f"VIKUNJA_SERVICE_PUBLICURL must be https://{HOST} (with or without the trailing "
                 "slash) - Vikunja builds its redirect URI from it")
        if env_of(dep, "VIKUNJA_AUTH_OPENID_ENABLED") != "true":
            fail("VIKUNJA_AUTH_OPENID_ENABLED is not true")
        if env_of(dep, "VIKUNJA_AUTH_LOCAL_ENABLED") != "false":
            fail("VIKUNJA_AUTH_LOCAL_ENABLED is not false - a local password door beside SSO is a "
                 "second, unbacked door. It defaults to true.")
        if env_of(dep, "VIKUNJA_SERVICE_ENABLEREGISTRATION") != "false":
            fail("VIKUNJA_SERVICE_ENABLEREGISTRATION is not false - it defaults to true")
        if env_of(dep, PREFIX + "AUTHURL") != ISSUER_URL:
            fail(f"{PREFIX}AUTHURL is not {ISSUER_URL} - it must name the per-provider issuer, which "
                 "is what issuer_mode: per_provider produces")
        if env_of(dep, PREFIX + "SCOPE") != "openid profile email":
            fail(f"{PREFIX}SCOPE must be 'openid profile email'. Adding `groups` switches on team "
                 "sync (spec D20); dropping `email` makes every login fail.")
        # The container's environment is `env:` PLUS every whole Secret named by `envFrom`, so both
        # sweeps have to cover both. A typo'd key added to vikunja-secrets reaches the pod as a dead
        # variable in exactly the shape this gate exists to catch, and an `env:`-only sweep reports
        # clean on it.
        configured = set(all_env_names(dep))
        for n in env_from_names(dep):
            configured |= set(secret_keys_of(docs, n, "vikunja"))
        dead = sorted(DEAD_KEYS & configured)
        if dead:
            fail(f"{dead} is not a Vikunja config key - it reads as configured and does nothing. "
                 "The Postgres port belongs inside VIKUNJA_DATABASE_HOST (pkg/db/db.go "
                 "parsePostgreSQLHostPort).")
        unknown = sorted(k for k in configured
                         if k.startswith("VIKUNJA_") and k not in KNOWN_KEYS)
        if unknown:
            fail(f"VIKUNJA_* names that are not in this gate's known-key list, counting both the "
                 f"Deployment's `env:` and every `envFrom` Secret: {unknown}. Either "
                 "the key is real and the list is stale, or it is a dead variable. Check which before "
                 "editing the list.")

        # --- database ---
        if env_of(dep, "VIKUNJA_DATABASE_TYPE") != "postgres":
            fail("VIKUNJA_DATABASE_TYPE is not postgres - Vikunja would use sqlite on the PVC, which "
                 "is a different backup path from the Database in `databases`")
        if env_of(dep, "VIKUNJA_DATABASE_HOST") != "postgres-rw.databases.svc.cluster.local:5432":
            fail("VIKUNJA_DATABASE_HOST must be postgres-rw.databases.svc.cluster.local:5432 - the "
                 "port is parsed out of this value, there is no separate port key")
        if env_of(dep, "VIKUNJA_DATABASE_MAXOPENCONNECTIONS") != "10":
            fail("VIKUNJA_DATABASE_MAXOPENCONNECTIONS is not 10 (spec D10). The default of 100 is the "
                 "stall bound, not a reservation; going much lower makes pool exhaustion block "
                 "requests silently.")
        if env_of(dep, "VIKUNJA_DATABASE_MAXIDLECONNECTIONS") != "2":
            fail("VIKUNJA_DATABASE_MAXIDLECONNECTIONS is not 2 (spec D10). The default of 50 is "
                 "backends parked while idle.")

        # --- mail ---
        if env_of(dep, "VIKUNJA_MAILER_ENABLED") != "true":
            fail("VIKUNJA_MAILER_ENABLED is not true. Reminders are already on behind it "
                 "(service.enableemailreminders and defaultsettings.overdue_tasks_reminders_enabled "
                 "both default true), so this is the only switch and the feature is decorative.")
        if env_of(dep, "VIKUNJA_MAILER_HOST") != "mail.techdelivery.es":
            fail("VIKUNJA_MAILER_HOST is not mail.techdelivery.es (spec D12)")
        if env_of(dep, "VIKUNJA_MAILER_PORT") != "465" or env_of(dep, "VIKUNJA_MAILER_FORCESSL") != "true":
            fail("the mailer must use 465 with VIKUNJA_MAILER_FORCESSL=true - that is implicit TLS "
                 "and it refuses a downgrade instead of falling back to plaintext")
        if env_of(dep, "VIKUNJA_SERVICE_TIMEZONE") != "GMT":
            fail("VIKUNJA_SERVICE_TIMEZONE is not GMT. It is already the default; the line is a pin "
                 "that documents intent (spec D13), so deleting it is a silent un-pinning.")

        # --- the Secret, and the two copies of one password ---
        # envFrom is read from every container, the same scope env_of and all_env_names use.
        names = env_from_names(dep)
        REQUIRED = (PREFIX + "CLIENTID", "VIKUNJA_DATABASE_PASSWORD", "VIKUNJA_SERVICE_SECRET")
        # `env:` wins over `envFrom` in Kubernetes: a key present in both reaches the container as the
        # literal in `env:` and the Secret's value is never read. Each of these three is exactly the
        # kind of value someone pins inline "just to test", and the unknown-key sweep cannot see it —
        # these names are in KNOWN_KEYS by definition, so the sweep passes them. A rotation would then
        # sit in the Secret, Reloader would restart the pod, and the pod would come back with the old
        # value, which is the worst possible ordering of surprises.
        shadowed = sorted(k for k in REQUIRED if k in all_env_names(dep))
        if shadowed:
            fail(f"{shadowed} is set in the Deployment's `env:` as well as in the envFrom Secret. `env:` "
                 "beats `envFrom`, so the Secret's value is silently overridden and rotating it does "
                 "nothing. These keys are meant to arrive from the Secret alone.")
        # The predicate demands all three keys in ONE Secret, because that is what the message below
        # claims and what scripts/setup-vikunja-secrets.sh writes. Accepting a Secret that carried any
        # one of them — what this loop used to do — let a half-populated Secret through, and then every
        # check under it reported on it as though it were the real one.
        sec_name = None
        for n in names:
            keys = secret_keys_of(docs, n, "vikunja")
            if keys and all(k in keys for k in REQUIRED):
                sec_name = n
                break
        if sec_name is None:
            fail(f"no Secret reachable from vikunja/vikunja by envFrom carries the OIDC client, the "
                 f"DB password and the service secret (envFrom names: {names})")
        else:
            for key, bp_key in ((PREFIX + "CLIENTID", "client_id"),
                                (PREFIX + "CLIENTSECRET", "client_secret")):
                app_val, _ = secret_key(docs, sec_name, "vikunja", key)
                if app_val in (None, ""):
                    fail(f"{sec_name} has no {key} (absent or empty) - an empty client credential is "
                         "not a credential, and empty compared against empty would read as agreement")
                elif rprov and app_val != rprov.get(bp_key):
                    fail(f"Vikunja's {key} does not match the blueprint's {bp_key} - the login will "
                         "fail with invalid_client, and the two files are edited apart")
            if secret_key(docs, sec_name, "vikunja", "VIKUNJA_SERVICE_SECRET")[0] in (None, ""):
                fail(f"{sec_name} has no VIKUNJA_SERVICE_SECRET. Without it Vikunja mints a random "
                     "one per boot and every Recreate logs every session out, with no error anywhere.")

            pw, _ = secret_key(docs, sec_name, "vikunja", "VIKUNJA_DATABASE_PASSWORD")
            # Absent is already the headline failure above — the envFrom predicate demands this key —
            # so the case left to catch here is the empty one, which would otherwise compare equal to
            # an empty copy on the CNPG side and pass.
            if pw in (None, ""):
                fail(f"{sec_name} has no VIKUNJA_DATABASE_PASSWORD (absent or empty)")
            dbsec = find(docs, "Secret", "vikunja-db-credentials", "databases")
            if dbsec is None:
                fail("no Secret vikunja-db-credentials in namespace databases - CNPG's DatabaseRole "
                     "has no credential to install")
            elif pw not in (None, ""):
                cnpg_pw, _ = secret_key(docs, "vikunja-db-credentials", "databases", "password")
                cnpg_user, _ = secret_key(docs, "vikunja-db-credentials", "databases", "username")
                if cnpg_pw is None:
                    fail("vikunja-db-credentials has no password key")
                elif cnpg_pw != pw:
                    fail("vikunja-secrets VIKUNJA_DATABASE_PASSWORD and vikunja-db-credentials "
                         "password differ - Vikunja gets password authentication failed and the "
                         "Database still reports Ready. Re-run scripts/setup-vikunja-secrets.sh with "
                         "FORCE=1 and rotate both.")
                if cnpg_user is None:
                    fail("vikunja-db-credentials has no username key - CNPG's basic-auth Secret needs "
                         "one and it must equal the role name")
                elif cnpg_user != env_of(dep, "VIKUNJA_DATABASE_USER"):
                    fail(f"vikunja-db-credentials username {cnpg_user!r} is not the Deployment's "
                         f"VIKUNJA_DATABASE_USER {env_of(dep, 'VIKUNJA_DATABASE_USER')!r}")

            # The mail half: SPOOF_PROTECTION=1 makes this structural, not cosmetic.
            from_email = env_of(dep, "VIKUNJA_MAILER_FROMEMAIL")
            user, _ = secret_key(docs, sec_name, "vikunja", "VIKUNJA_MAILER_USERNAME")
            if user is None:
                fail(f"{sec_name} has no VIKUNJA_MAILER_USERNAME")
            elif from_email != user:
                fail(f"VIKUNJA_MAILER_FROMEMAIL is {from_email!r} but the mailbox is {user!r}. The "
                     "relay runs SPOOF_PROTECTION=1, so an authenticated user may only send as its own "
                     "address - this is refused at MAIL FROM while the pod reports healthy.")
            if secret_key(docs, sec_name, "vikunja", "VIKUNJA_MAILER_PASSWORD")[0] in (None, ""):
                fail(f"{sec_name} has no VIKUNJA_MAILER_PASSWORD")

    ing = find(docs, "Ingress", "vikunja", "vikunja")
    if ing is None:
        fail("no Ingress vikunja/vikunja")
    else:
        # Why the Ingress gets its own structural check and the Deployment does not: a mis-nested
        # Ingress key is a CORE-type violation, and no offline gate here can see core types.
        # crd-check walks vendored CRDs only, namespace-check walks namespaces only, and
        # `make dry-run` — the one gate that asks the API server — needs an admin context this
        # identity does not have. mealie/mealie.yaml records the same trap biting on 2026-10-22.
        leaked = sorted(k for k in ("rules", "tls", "ingressClassName", "defaultBackend")
                        if k in (ing.get("metadata") or {}))
        if leaked:
            fail(f"Ingress vikunja/vikunja carries {leaked} under metadata instead of spec - the API "
                 "server rejects it and no offline gate but make dry-run will tell you")
        spec = ing.get("spec") or {}
        hosts = [r.get("host") for r in (spec.get("rules") or [])]
        if hosts != [HOST]:
            fail(f"Ingress vikunja/vikunja serves {hosts}, expected ['{HOST}'] - PUBLICURL, the "
                 "blueprint redirect URI and the wildcard certificate all key off this host")
        if not spec.get("tls"):
            fail("Ingress vikunja/vikunja has no tls block - titan-tls has to terminate TLS for this host")
        else:
            # tls-reflection-check proves this namespace is *allowed* the mirrored Secret; it cannot see
            # whether this Ingress asks for it. A tls block naming some other Secret, or none, applies
            # cleanly, reports Accepted, and Traefik answers with its fallback certificate.
            tls_names = tls_secret_names_of(spec)
            if tls_names != ["titan-tls"]:
                fail(f"Ingress vikunja/vikunja's tls blocks name {tls_names}, expected ['titan-tls'] - "
                     "Reflector mirrors that one into this namespace, and anything else is Traefik's "
                     "fallback certificate behind an Accepted Ingress")

    db = find(docs, "Database", "vikunja", "databases")
    if db is None:
        fail("no Database vikunja in namespace databases")
    else:
        # Bound once and used twice, on purpose. The guard used to be `(db.get("spec") or {})` inline in
        # the condition while the message below indexed `db['spec']` directly, so a Database with no
        # `spec` at all passed the guard and then raised KeyError in the failure path — and a
        # mis-indented `name:` under `metadata` produces exactly that shape. This gate runs before
        # crd-check in `make check`, so that traceback masked the gate that would have named the cause.
        db_spec = db.get("spec") or {}
        if dep is not None and db_spec.get("name") != env_of(dep, "VIKUNJA_DATABASE_DATABASE"):
            fail(f"Database vikunja creates {db_spec.get('name')!r} but the Deployment connects to "
                 f"{env_of(dep, 'VIKUNJA_DATABASE_DATABASE')!r}")
    role = find(docs, "DatabaseRole", "vikunja", "databases")
    if role is None:
        fail("no DatabaseRole vikunja in namespace databases")
    else:
        if not (role.get("spec") or {}).get("login"):
            fail("DatabaseRole vikunja is not login: true - CNPG creates roles NOLOGIN by default, "
                 "the Database reports Ready and every connection fails pointing somewhere else")
        if not (role.get("spec") or {}).get("comment"):
            fail("DatabaseRole vikunja has no spec.comment - it is the only DatabaseRole field the CRD "
                 "does not default, so it is the only one that bumps metadata.generation and makes the "
                 "instance manager re-apply the role and clear a stale status.message (#154). Without "
                 "it a false RBAC denial sits there forever alongside applied: true.")
        if ((role.get("spec") or {}).get("passwordSecret") or {}).get("name") != "vikunja-db-credentials":
            fail("DatabaseRole vikunja does not point at vikunja-db-credentials")

    if failures:
        print(f"vikunja-check: {len(failures)} problem(s)")
        return 1
    print("vikunja-check: blueprint, mount, app config, OIDC client, DB credential and mail FROM all agree")
    return 0


if __name__ == "__main__":
    sys.exit(main())
