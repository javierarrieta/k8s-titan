#!/usr/bin/env python3
"""oidc-check: coder's OIDC client, coder's own copy of it, and authentik's mount, all agreeing.

The declarative version of coder's OIDC client is a blueprint template committed in git
(apply/50-apps/auth/blueprints/coder.yaml). It carries two placeholders; scripts/setup-coder-secrets.sh
substitutes them and writes a sops-encrypted Secret that the authentik worker mounts and applies.
Coder is separately given the same client ID and secret in coder-secrets.

That is three places one credential can be wrong, and every way it can be wrong is quiet:

  * the rendered Secret drifts from the reviewed template - git says one thing, authentik applies
    another, and no reviewer ever sees the applied artifact;
  * coder's copy and authentik's copy disagree - every login fails with an OIDC error that reads
    like a coder bug;
  * the Secret exists but the HelmRelease does not mount it - perfectly valid, perfectly inert,
    and the failure looks identical to "the blueprint was never written";
  * a placeholder survives substitution - authentik then has a client literally named
    ${CODER_OIDC_CLIENT_ID}.

Like db-url-check this is reference-driven and refuses to report clean when a Secret will not
decrypt. When coder's OIDC values do not exist yet it says so and counts zero, which is honest and
empty rather than a pass over nothing.
"""
import os
import re
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from sopsload import find, load_docs, load_text, secret_key  # noqa: E402

import yaml  # noqa: E402

TEMPLATE = "apply/50-apps/auth/blueprints/coder.yaml"
PLACEHOLDERS = ("CODER_OIDC_CLIENT_ID", "CODER_OIDC_CLIENT_SECRET")
CALLBACK = "https://coder.titan.arrieta.eu/api/v2/users/oidc/callback"
BLUEPRINT_SECRET = "authentik-coder-blueprint"
BLUEPRINT_KEY = "coder.yaml"


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


def main():
    root = sys.argv[1] if len(sys.argv) > 1 else "apply"
    docs = load_docs(root)
    checked = bad = 0

    def fail(msg):
        nonlocal bad
        print(f"FAIL: {msg}")
        bad += 1

    # --- A. the reviewed template itself -------------------------------------------------------
    tpl_text = load_text(TEMPLATE)
    if tpl_text is None:
        sys.exit(f"oidc-check: {TEMPLATE} is missing - the gate has no source of truth to check "
                 f"against; refusing to report clean")
    try:
        tpl = yaml.safe_load(tpl_text)
    except yaml.YAMLError as exc:
        sys.exit(f"oidc-check: {TEMPLATE} is not valid YAML: {exc}")
    checked += 1

    pe, ae = provider_entry(tpl), app_entry(tpl)
    if pe is None:
        fail(f"{TEMPLATE} declares no authentik_providers_oauth2.oauth2provider entry")
    if ae is None:
        fail(f"{TEMPLATE} declares no authentik_core.application entry")
    if pe and ae:
        checked += 1
        if (ae.get("attrs") or {}).get("slug") != "coder":
            fail("the application slug is not 'coder' - the issuer URL coder is configured with is "
                 "derived from it, so the slug is load-bearing, not cosmetic")
        uris = [u.get("url") for u in ((pe.get("attrs") or {}).get("redirect_uris") or [])]
        if uris != [CALLBACK]:
            fail(f"redirect_uris is {uris}, expected exactly ['{CALLBACK}'] - coder registers its "
                 f"OIDC callback at that path and nowhere else")
        modes = [u.get("matching_mode") for u in ((pe.get("attrs") or {}).get("redirect_uris") or [])]
        if any(m != "strict" for m in modes):
            fail(f"redirect_uri matching_mode is {modes}; a prefix match here is a redirect bypass")

    found = set(re.findall(r"\$\{([A-Z_]+)\}", tpl_text))
    checked += 1
    if found != set(PLACEHOLDERS):
        fail(f"{TEMPLATE} placeholders are {sorted(found)}, expected {sorted(PLACEHOLDERS)} - "
             f"setup-coder-secrets.sh substitutes exactly these two and nothing else")

    # --- B. coder's copy, and the rendered artifact --------------------------------------------
    cid, cdata = secret_key(docs, "coder-secrets", "coder", "oidc-client-id")
    if cdata is None:
        print("oidc-check: coder-secrets not present - 0 rendered OIDC artifacts to reconcile "
              "(run scripts/setup-coder-secrets.sh)")
        print(f"oidc-check: {checked} template check(s) run, {bad} mismatch(es)")
        sys.exit(1 if bad else 0)

    csec, _ = secret_key(docs, "coder-secrets", "coder", "oidc-client-secret")
    if not cid or not csec:
        fail("coder-secrets is present but oidc-client-id or oidc-client-secret is empty")
    checked += 1

    bp_secret = find(docs, "Secret", BLUEPRINT_SECRET, "auth")
    if bp_secret is None:
        fail(f"coder has OIDC credentials but {BLUEPRINT_SECRET} (namespace auth) is not in the "
             f"tree - authentik has no such client, so every coder login will fail")
    else:
        checked += 1
        rendered = (bp_secret.get("stringData") or {}).get(BLUEPRINT_KEY)
        if rendered is None:
            fail(f"{BLUEPRINT_SECRET} has no '{BLUEPRINT_KEY}' key - the worker only picks up "
                 f"keys ending in .yaml, so an empty Secret is indistinguishable from no blueprint")
        else:
            checked += 1
            leftover = re.findall(r"\$\{[A-Z_]+\}", rendered)
            if leftover:
                fail(f"rendered blueprint still contains unsubstituted placeholders {leftover} - "
                     f"authentik would register a client literally named {leftover[0]}")
            # Named before the whole-document comparison, so the message names the credential that
            # actually moved instead of reporting a generic document mismatch.
            try:
                rbp = yaml.safe_load(rendered) or {}
                rattrs = next((e.get("attrs") or {}) for e in (rbp.get("entries") or [])
                              if e.get("model") == "authentik_providers_oauth2.oauth2provider")
            except yaml.YAMLError:
                rattrs = {}
            if rattrs.get("client_id") != cid:
                fail(f"authentik's client_id is {rattrs.get('client_id')!r} but coder is "
                     f"configured with {cid!r} - the two copies of this credential disagree")
            elif rattrs.get("client_secret") != csec:
                fail("authentik's client_secret does not match coder-secrets/oidc-client-secret - "
                     "every login will fail with an OIDC error that reads like a coder bug")
            else:
                checked += 1
            expected = (tpl_text.replace("${CODER_OIDC_CLIENT_ID}", cid or "")
                               .replace("${CODER_OIDC_CLIENT_SECRET}", csec or ""))
            try:
                if yaml.safe_load(rendered) != yaml.safe_load(expected):
                    fail(f"{BLUEPRINT_SECRET}:{BLUEPRINT_KEY} is not the committed template with "
                         f"the two credentials substituted - the applied artifact has drifted from "
                         f"the reviewed source; re-run scripts/setup-coder-secrets.sh")
                checked += 1
            except yaml.YAMLError as exc:
                fail(f"rendered blueprint is not valid YAML: {exc}")

    # --- C. is the blueprint actually mounted? --------------------------------------------------
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

    print(f"oidc-check: {checked} check(s) run, {bad} mismatch(es)")
    sys.exit(1 if bad else 0)


if __name__ == "__main__":
    main()
