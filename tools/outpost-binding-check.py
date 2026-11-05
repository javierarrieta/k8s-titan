#!/usr/bin/env python3
"""outpost-binding-check: the outpost's own admission set, asserted instead of described.

WHY THIS EXISTS. Since #242 and #246 removed the forwardAuth Middleware from both Grafanas, exactly
one host is still gated by this outpost for group membership: `tesla.titan.arrieta.eu`. Its own login
is Tesla's OAuth (`TESLA_AUTH_HOST=auth.tesla.com`), which proves a person signed in and proves
nothing about whether that person belongs to this household, so the outpost's application bindings are
the ONLY thing between that host and anyone who can produce a Tesla account. `apply/60-tesla/
teslamate.yaml` and `docs/teslamate-runbook.md` §9 both say that in as many words.

Nothing proved it. `make grafana-oidc-check` asserts the exact binding set for the two Grafana
applications — and deliberately so, because those bindings became the whole gate when their edge gate
went. The `tesla` application is the same class of claim with no gate behind it: `blueprint-mount-check`
proves each binding names a group this tree DECLARES (a typo denies), but never that the set is the
reviewed one. Drop one of the three bindings and the host silently admits a wider crowd behind a
perfectly healthy login page, which is the failure shape this repo keeps meeting and keeps answering
with a gate.

It also asserts the three provider values every surrounding comment leans on. `apply/60-tesla/
grafana.yaml` justifies "removing this host's gate widened nothing" by saying the outpost has one
provider, `forward_domain` over `titan.arrieta.eu`, resolving this host to the `tesla` application —
and `docs/teslamate-runbook.md` §9 rejects adding `/live/websocket` to `skip_path_regex` on the
grounds that the exemption would apply to every host under the apex. Both arguments are true only
while those values are. Change `cookie_domain`, add a second provider, or widen `skip_path_regex` and
the prose above it becomes folklore — the exact defect the tesla-grafana Ingress header already
documents as having happened once (an inherited claim about an iframe nobody had checked).

WHAT IT CHECKS, all of it from the plaintext blueprint ConfigMap in the tree:

  1. The blueprint file exists, parses, and holds exactly one `authentik_core.application` with the
     reviewed slug. Two applications in one blueprint would make every assertion below ambiguous.
  2. That application's `policy_engine_mode` is `any`, written out rather than inherited. Under `all`
     the same three rows demand membership of every group at once and lock out everyone they were
     written to admit.
  3. The policybindings targeting that application name EXACTLY the reviewed group set. Exact set
     equality, not "at least one": a dropped binding widens who gets in and an added one narrows it,
     and both read as a working login page.
  4. Exactly one `authentik_providers_proxy.proxyprovider`, in `forward_domain` mode with the reviewed
     `cookie_domain`, and it is the provider the outpost actually manages. This is what makes "the
     outpost gates this host" a fact rather than a hope.
  5. `skip_path_regex` is exactly the reviewed value. Every path added to it is exempt on EVERY host
     under the apex, which is the blast radius §9 declined for `/live/websocket`; if it changes, that
     rejection needs re-reading rather than inheriting.

VACUITY. A missing file, an unreadable blueprint, no application, no bindings, no provider or no
outpost is a failure, never a clean run. A gate that scans nothing and prints a count is the failure
mode this file exists to prevent.

WHAT IT DOES NOT PROVE, in order of how much it matters:

  * It reads the committed tree, not authentik's database. Committed bindings are not applied
    bindings; `make dry-run` and a blueprint apply are what close that, and this repo has already been
    bitten by a blueprint that was committed, built green and never reached the worker.
  * It does not prove the policy behind the bindings is the policy meant. Which accounts are IN
    `titan-family` is a row in authentik's database, exactly as `ingress-auth` cannot see an outpost
    provider with no gate behind it.
  * It says nothing about the two Grafanas. Their bindings are `grafana-oidc-check`'s job, on their
    own templates, and this script never reads those files.
"""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from sopsload import load_text, load_tolerating_tags  # noqa: E402

import yaml  # noqa: E402

# The reviewed admission set. Changing a line here is a decision about who may read this household's
# car location history, and it has to be made twice: once in the blueprint, once here.
BLUEPRINT_PATH = "apply/50-apps/auth/tesla-outpost-blueprint.yaml"
BLUEPRINT_KEY = "tesla.yaml"
APP_SLUG = "tesla"
GROUPS = ("titan-family", "titan-grafana-admins", "titan-tesla-grafana-admins")
POLICY_ENGINE_MODE = "any"
PROVIDER_MODE = "forward_domain"
COOKIE_DOMAIN = "titan.arrieta.eu"
SKIP_PATH_REGEX = r"^/\.well-known"

APP_MODEL = "authentik_core.application"
BINDING_MODEL = "authentik_policies.policybinding"
GROUP_MODEL = "authentik_core.group"
PROVIDER_MODEL = "authentik_providers_proxy.proxyprovider"
OUTPOST_MODEL = "authentik_outposts.outpost"


def find_value(tag, model, key):
    """Value of a rebuilt `!Find [model, [key, value]]` tag, or None if this is not that shape.

    Matching the rebuilt structure rather than the raw text is what stops this passing when someone
    writes the same lookup with the arguments swapped or the inner pair flattened.
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


def main():
    root = sys.argv[1] if len(sys.argv) > 1 else "."
    path = os.path.join(root, BLUEPRINT_PATH)
    if not os.path.isfile(path):
        print(f"FAIL: {BLUEPRINT_PATH} is missing - the outpost's admission set has no source of "
              "truth to check, and this gate cannot report clean over an absent blueprint")
        return 1
    cm_text = load_text(path)
    if cm_text is None:
        print(f"FAIL: {BLUEPRINT_PATH} could not be read")
        return 1
    try:
        cm = yaml.safe_load(cm_text)
    except yaml.YAMLError as exc:
        print(f"FAIL: {BLUEPRINT_PATH} is not valid YAML: {exc}")
        return 1
    body = ((cm or {}).get("data") or {}).get(BLUEPRINT_KEY)
    if not body:
        print(f"FAIL: {BLUEPRINT_PATH} has no {BLUEPRINT_KEY!r} key - the worker only picks up keys "
              "ending in .yaml, so a renamed key is an outpost with no blueprint, not an error")
        return 1
    try:
        bp = load_tolerating_tags(body) or {}
    except yaml.YAMLError as exc:
        print(f"FAIL: the blueprint body is not valid YAML: {exc}")
        return 1

    entries = bp.get("entries") or []
    checked = bad = 0

    def fail(msg):
        nonlocal bad
        print(f"FAIL: {msg}")
        bad += 1

    # --- 1 and 2: the application, and what its bindings MEAN ----------------------------------
    apps = [e for e in entries if e.get("model") == APP_MODEL]
    if len(apps) != 1:
        print(f"FAIL: {BLUEPRINT_PATH} declares {len(apps)} {APP_MODEL} entries, expected exactly "
              "one - with more than one it is ambiguous which application the outpost gates this host "
              "through, and every assertion below would be about the wrong one")
        return 1
    checked += 1
    app = apps[0]
    if (app.get("attrs") or {}).get("slug") != APP_SLUG:
        fail(f"the application slug is {(app.get('attrs') or {}).get('slug')!r}, expected "
             f"{APP_SLUG!r} - the outpost's forward_domain resolution and every comment that reasons "
             "about 'the tesla application' both name this slug")
    mode = (app.get("attrs") or {}).get("policy_engine_mode")
    checked += 1
    if mode != POLICY_ENGINE_MODE:
        fail(f"application {APP_SLUG!r} has policy_engine_mode {mode!r}, expected "
             f"{POLICY_ENGINE_MODE!r}. Under `all` these bindings demand membership of every group at "
             "once and lock out the people they were written to admit; under an omitted value the "
             "behaviour is a default a future authentik release is free to change")

    # --- 3: the admission set itself -------------------------------------------------------------
    app_id = app.get("id")
    bindings = []
    for e in entries:
        if e.get("model") != BINDING_MODEL:
            continue
        target = (e.get("identifiers") or {}).get("target")
        if target == f"!KeyOf {app_id}" or keyof(target) == app_id \
                or find_value(target, APP_MODEL, "slug") == APP_SLUG:
            bindings.append(e)
    checked += 1
    groups = sorted({g for e in bindings
                     for g in [find_value((e.get("attrs") or {}).get("group"), GROUP_MODEL, "name")]
                     if g})
    unresolved = [e for e in bindings
                  if find_value((e.get("attrs") or {}).get("group"), GROUP_MODEL, "name") is None]
    if unresolved:
        fail(f"{len(unresolved)} policybinding(s) on {APP_SLUG!r} do not name a group through "
             "`!Find [authentik_core.group, [name, X]]`, so this gate cannot tell who they admit. "
             "An unresolvable binding is not a skip - a binding naming a group that does not exist "
             "DENIES, and once any binding exists the no-bindings allow-all stops applying")
    expected = sorted(GROUPS)
    if not bindings:
        fail(f"nothing binds a policy to application {APP_SLUG!r}. With no binding authentik's engine "
             "allows every authenticated account, and teslamate's own login is Tesla's OAuth - so "
             "this host, which is car location history, would be readable by any authentik user "
             "behind a green-looking login page")
    elif groups != expected:
        lost = sorted(set(expected) - set(groups))
        gained = sorted(set(groups) - set(expected))
        fail(f"application {APP_SLUG!r} binds {groups}, expected exactly {expected} - "
             f"missing {lost}, extra {gained}. Either direction changes who can read this host. "
             "If the change was deliberate, update GROUPS in this script in the same commit so the "
             "decision gets reviewed twice")

    # --- 4: the provider the outpost actually manages --------------------------------------------
    providers = [e for e in entries if e.get("model") == PROVIDER_MODEL]
    if len(providers) != 1:
        print(f"FAIL: {BLUEPRINT_PATH} declares {len(providers)} {PROVIDER_MODEL} entries, expected "
              "exactly one. The whole 'removing a host's middleware widened nothing' argument in "
              "apply/60-tesla/grafana.yaml rests on there being one provider resolving every host "
              "under the apex to one application; a second provider makes that claim unprovable")
        return 1
    checked += 1
    pattrs = providers[0].get("attrs") or {}
    if pattrs.get("mode") != PROVIDER_MODE:
        fail(f"the proxy provider's mode is {pattrs.get('mode')!r}, expected {PROVIDER_MODE!r} - "
             "the reasoning that this host is gated at all is specific to forward_domain")
    checked += 1
    if pattrs.get("cookie_domain") != COOKIE_DOMAIN:
        fail(f"cookie_domain is {pattrs.get('cookie_domain')!r}, expected {COOKIE_DOMAIN!r}. This is "
             "the field that decides which hosts the outpost cookie is sent to, so it is the field "
             "that decides which hosts 'the outpost is in front of it' is true for")
    checked += 1
    if pattrs.get("skip_path_regex") != SKIP_PATH_REGEX:
        fail(f"skip_path_regex is {pattrs.get('skip_path_regex')!r}, expected {SKIP_PATH_REGEX!r}. "
             "Every path added here is exempt on EVERY host under the apex, which is why "
             "docs/teslamate-runbook.md §9 declined to exempt /live/websocket. If this moved, §9's "
             "rejection has to be re-read rather than inherited")
    checked += 1

    outposts = [e for e in entries if e.get("model") == OUTPOST_MODEL]
    if not outposts:
        fail(f"no {OUTPOST_MODEL} entry - nothing manages this provider, so no outpost is in front of "
             "anything and every comment naming 'the outpost' is describing an object that is not "
             "created")
    else:
        checked += 1
        listed = [keyof(p) or p for o in outposts for p in ((o.get("attrs") or {}).get("providers") or [])]
        if providers[0].get("id") not in listed:
            fail(f"the outpost manages {listed}, which does not include provider "
                 f"{providers[0].get('id')!r} - the bindings above would then gate nothing")

    print(f"outpost-binding-check: application {APP_SLUG!r} binds exactly {groups} under "
          f"policy_engine_mode {mode!r}; provider mode {pattrs.get('mode')!r}, cookie_domain "
          f"{pattrs.get('cookie_domain')!r}, skip_path_regex {pattrs.get('skip_path_regex')!r}; "
          f"{checked} check(s) run, {bad} mismatch(es)")
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
