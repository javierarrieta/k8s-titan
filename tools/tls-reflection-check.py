#!/usr/bin/env python3
"""tls-reflection-check: a namespace may serve TLS from a reflected Secret only if it is on that Secret's allow-list.

WHY THIS EXISTS. `titan-tls` is produced in namespace `certificates` and copied into consuming
namespaces by Reflector, and the allow-list is two comma-separated annotations on the `Certificate`'s
`secretTemplate`. An Ingress that names `titan-tls` in a namespace that was never added gets applied
happily, reports `Accepted=True`, and Traefik answers that host with its fallback certificate because
the Secret simply is not there. There is no red release and `make dry-run` cannot see it: the Secret is
created out of band by Reflector, so the API server is asked about nothing this tree fails to declare.
AGENTS.md already says "a new consuming namespace means editing that file", and this PR is the case that
proved prose was not enough — `gatus` had to be added to the list, and it is the ninth namespace added
that way by hand, with nothing comparing the two lists that have to agree.

`tools/sure-check.py:598-611` does exactly this check for `sure` alone and `tools/mealie-check.py:249`
does a weaker one for `mealie` alone. Both were written because the failure is invisible. This is the
same rule, applied to the whole tree instead of to whichever app was being added when someone noticed.

WHAT IT CHECKS, from the built stream:

  1. Every `Certificate` carrying `reflector.v1.k8s.emberstack.com/reflection-allowed-namespaces` is
     indexed by the Secret it produces. Today: `titan-tls`, `coder-tls`, `tesla-streaming-tls`.
  2. Every built `Ingress` whose `tls[].secretName` names one of those Secrets, and every
     `HelmRelease` whose rendered `values` mention one (sure's chart and authentik's both reach
     `titan-tls` that way and produce no built `Ingress` for this tree to see), is a consumer of it.
  3. Each consumer namespace must appear in BOTH `reflection-allowed-namespaces` and
     `reflection-auto-namespaces`. Both, not either: the first is what lets a namespace pull the Secret
     and the second is what makes Reflector do it without being asked, and `sure-check` already demands
     membership in both for the one app it covers.
  4. The two lists must agree with each other. They are maintained as one pair everywhere in this tree,
     and a namespace in one and not the other is a half-added consumer.
  5. AGENTS.md carries a copy of the allow-list in prose ("today `apps,auth,...`") on the line naming
     the Certificate called PROSE_CERT. That copy must match the annotation. One list kept twice is one
     edit away from a silent split — the same reasoning as `db-url-check`, applied to a list instead of
     a URL. The Secret is found by the Certificate's NAME rather than by the Secret it writes, so
     renaming the Secret cannot quietly downgrade this check to a note.

VACUITY. No reflected `Certificate` in the build, no consumer of any of them, an empty allow-list, an
unreadable AGENTS.md, or an AGENTS.md that no longer carries the prose copy is a failure, never a clean
run. A gate that scans nothing and prints a count is the failure mode this file exists to prevent.

WHAT IT DOES NOT PROVE, in order of how much it matters:

  * It proves a namespace is ALLOWED a Secret, not that it RECEIVED one. Reflector running, the source
    Secret being issued, and the mirror landing are live facts; a cold cluster with cert-manager behind
    is a tree that passes this gate and has no certificate anywhere. `make dry-run` does not close this
    either — see the note above about who creates the Secret.
  * A consumer is found by NAME. A chart that renders its TLS block from a value this tree never sets
    is invisible to it, and so is a `HelmRelease` that names the Secret only inside a block its own
    values keep disabled — that second case asks for MORE reflection than the host needs, so it fails
    safe, but it means an allow-list entry can exist for a consumer that is not actually serving. A
    Secret name that no `Certificate` in this build produces is reported as a note, so it cannot be
    mistaken for coverage.
  * It does not judge whether a namespace SHOULD be on the list. Every entry is a decision made
    elsewhere; a namespace on the list that consumes nothing is reported as a note, not a failure,
    because a namespace may be added ahead of the workload that needs it — which is how `sure` and
    `mealie` were both added.
"""
import re
import sys
from pathlib import Path

import yaml

ALLOWED = "reflector.v1.k8s.emberstack.com/reflection-allowed-namespaces"
AUTO = "reflector.v1.k8s.emberstack.com/reflection-auto-namespaces"
# The Certificate whose allow-list AGENTS.md quotes in prose, and the sentence shape to look for.
PROSE_CERT = "titan-wildcard"
PROSE_RE = re.compile(r"today `([^`\n]+)`")


def split_list(value):
    return [part.strip() for part in (value or "").split(",") if part.strip()]


def strings(node):
    """Every string anywhere inside a HelmRelease values tree, however deeply nested."""
    if isinstance(node, str):
        yield node
    elif isinstance(node, dict):
        for value in node.values():
            yield from strings(value)
    elif isinstance(node, list):
        for value in node:
            yield from strings(value)


def main():
    if len(sys.argv) != 2:
        print("usage: tls-reflection-check.py <repo-root> < built-yaml-stream")
        return 2
    try:
        docs = [doc for doc in yaml.safe_load_all(sys.stdin) if doc]
    except yaml.YAMLError as exc:
        print(f"FAIL: stdin is not parseable YAML: {exc}")
        return 1

    failures = []
    notes = []

    certs = {}
    for doc in docs:
        if doc.get("kind") != "Certificate":
            continue
        spec = doc.get("spec") or {}
        secret = spec.get("secretName")
        anns = (spec.get("secretTemplate") or {}).get("annotations") or {}
        if not secret or ALLOWED not in anns:
            continue
        if secret in certs:
            failures.append(f"two Certificates produce Secret {secret!r} with Reflector annotations; the "
                            "allow-list cannot be resolved unambiguously")
            continue
        meta = doc.get("metadata") or {}
        certs[secret] = (meta.get("namespace"), meta.get("name"), anns)
    if not certs:
        print("FAIL: no reflected Certificate in the build - tls-reflection cannot pass vacuously by "
              "forgetting the Certificates that carry the Reflector annotations")
        return 1

    consumers = {secret: {} for secret in certs}
    unproduced = {}
    for doc in docs:
        kind = doc.get("kind")
        ns = (doc.get("metadata") or {}).get("namespace")
        spec = doc.get("spec") or {}
        who = f"{kind} {ns}/{(doc.get('metadata') or {}).get('name')}"
        if kind == "Ingress":
            for block in spec.get("tls") or []:
                secret = (block or {}).get("secretName")
                if secret in consumers:
                    consumers[secret].setdefault(ns, []).append(who)
                elif secret:
                    unproduced.setdefault(secret, []).append(who)
        elif kind == "HelmRelease":
            hit = {s for s in strings(spec.get("values") or {}) if s in consumers}
            for secret in hit:
                consumers[secret].setdefault(ns, []).append(who)
    if not any(consumers.values()):
        print("FAIL: no built Ingress or HelmRelease consumes a reflected Certificate - tls-reflection "
              "cannot pass vacuously on a tree with no consumers")
        return 1

    for secret, (cert_ns, cert_name, anns) in sorted(certs.items()):
        allowed = split_list(anns.get(ALLOWED))
        auto = split_list(anns.get(AUTO))
        where = f"Certificate {cert_ns}/{cert_name} (Secret {secret})"
        if not allowed:
            failures.append(f"{where}: {ALLOWED} is empty or absent, so no namespace can receive the Secret")
        if not auto:
            failures.append(f"{where}: {AUTO} is empty or absent, so Reflector mirrors the Secret nowhere")
        if set(allowed) != set(auto):
            notes.append(f"NOTE: {where} lists {sorted(set(allowed) ^ set(auto))} in one of "
                         f"{ALLOWED} / {AUTO} but not both. Every other reflected Certificate here keeps "
                         "the pair identical; a namespace in one and not the other is half-added.")

        used = consumers[secret]
        for ns in sorted(used):
            missing = [name for name, listed in ((ALLOWED, allowed), (AUTO, auto)) if ns not in listed]
            if missing:
                failures.append(
                    f"{', '.join(used[ns])} serves TLS from Secret {secret!r}, but namespace {ns!r} is "
                    f"absent from {' and '.join(missing)} on {where}. Reflector never copies the Secret "
                    "there, Traefik falls back to its default certificate, and the host answers over a "
                    "cert that does not match its name - with the Ingress reporting Accepted and "
                    "make dry-run unable to see it, because Reflector rather than this tree creates that "
                    "Secret. Add the namespace to both annotations.")
        unused = sorted(set(allowed) - set(used))
        if unused:
            notes.append(f"NOTE: {where} reflects into {', '.join(unused)} but no built Ingress or "
                         "HelmRelease there names the Secret. Fine if the workload is coming or a chart "
                         "reaches it by a path this gate cannot see; delete the entry if neither is true.")

    for secret, who in sorted(unproduced.items()):
        notes.append(f"NOTE: {', '.join(sorted(set(who)))} names TLS Secret {secret!r}, which no "
                     "Certificate in this build produces. Fine if something outside this tree issues it; "
                     "otherwise that host has no certificate and this gate cannot see it, because it only "
                     "knows Secrets a Certificate here declares.")

    # The prose copy is bound to the Certificate by NAME, not by the Secret it writes, so renaming the
    # Secret cannot downgrade this comparison to a silent note.
    prose_secret = next((s for s, (_, cname, _) in certs.items() if cname == PROSE_CERT), None)
    agents = Path(sys.argv[1]) / "AGENTS.md"
    reflected = certs.get(prose_secret) if prose_secret else None
    prose_compared = False
    if not agents.is_file():
        failures.append(f"no AGENTS.md at {agents} - the prose copy of the allow-list cannot be compared")
    else:
        quoted = None
        for line in agents.read_text().splitlines():
            if PROSE_CERT in line:
                match = PROSE_RE.search(line)
                if match:
                    quoted = split_list(match.group(1))
        if quoted is None:
            failures.append(f"AGENTS.md no longer carries the `today \\`...\\`` copy of the "
                            f"{PROSE_CERT} allow-list on the line naming {PROSE_CERT}.yaml. Either restore "
                            "it or delete the claim, because a doc that says the allow-list is one thing "
                            "while the annotation says another is how the next namespace gets added to "
                            "the wrong one of the two.")
        elif reflected is None:
            notes.append(f"NOTE: AGENTS.md quotes the {PROSE_CERT} allow-list but no Certificate named "
                         f"{PROSE_CERT} is in the build with Reflector annotations, so the prose copy was "
                         "not compared.")
        else:
            prose = set(quoted)
            annotation = set(split_list(reflected[2].get(ALLOWED, "")))
            prose_compared = True
            if prose != annotation:
                failures.append(f"AGENTS.md's prose allow-list {sorted(prose)} does not match "
                                f"reflection-allowed-namespaces {sorted(annotation)} on Certificate "
                                f"{reflected[0]}/{reflected[1]} (Secret {prose_secret}): "
                                f"only in AGENTS.md {sorted(prose - annotation)}, only in the annotation "
                                f"{sorted(annotation - prose)}. Fix AGENTS.md to match the annotation.")

    if failures:
        print("FAIL: a namespace serves TLS from a Secret Reflector will not deliver, or the two copies "
              "of an allow-list disagree:")
        for line in failures:
            print(f"  {line}")
        return 1

    total = sum(len(v) for v in consumers.values())
    prose_line = ("and AGENTS.md's prose copy matches the annotation it quotes" if prose_compared
                  else "but the AGENTS.md prose copy was NOT compared - see the note below")
    print(f"tls-reflection: {len(certs)} reflected Certificate(s) ({', '.join(sorted(certs))}); "
          f"{total} consumer(s) across {len({ns for c in consumers.values() for ns in c})} namespace(s), "
          f"every one named by both Reflector annotations, {prose_line}")
    for note in notes:
        print(f"  {note}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
