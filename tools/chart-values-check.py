#!/usr/bin/env python3
"""Render every HelmRelease's values against the exact chart version it pins.

WHY THIS EXISTS. PR #176 bumped `cert-manager-webhook-ovh` 0.6.0 -> 0.9.19 and CI went
green. The chart cannot install with those values. Chart 0.7.0 had added a
`values.schema.json` that requires `issuers[].ovhAuthenticationMethod` and rejects the
older `consumerKeyRef` name, so helm refuses to render the release at all:

    Error: values don't meet the specifications of the schema(s):
    - at '/issuers/0': missing property 'ovhAuthenticationMethod'

Nothing in this repo could see that. `kustomize-check` builds the `HelmRelease` object,
which is a perfectly legal object carrying an opaque `values` map. `crd-check` walks that
same object against the vendored Flux CRD, which declares `values` as
`x-kubernetes-preserve-unknown-fields` and so accepts anything. `release-secrets` proves a
Secret name and namespace, never the shape around it. `make dry-run` asks the API server
about the `HelmRelease`, not about the chart's own schema. The only thing that knows a
chart's value contract is the chart, and no gate here had ever opened one.

WHAT IT DOES. For each `HelmRelease`: resolve its `HelmRepository` / `OCIRepository`
source, pull the pinned chart version, write `spec.values` to a file, run `helm template`.
A non-zero render fails the gate. That catches chart schema violations, the template-time
`fail` guards charts write for themselves (the OVH chart has a `validator.yaml` that fails
on a contradictory authentication block), renamed values, and values that produce a
manifest the chart's own helpers reject.

WHAT IT NEEDS. `helm` on PATH and network access to every chart source. It needs no
cluster, no kubeconfig and no age key, and it never reads a Secret: every value it renders
is plaintext in this tree, because secrets are referenced by name and never inlined. That
is why it is its own CI job and not part of `check-ci`, whose contract is "provable from
the tree alone, no network". See `.github/workflows/chart-gate.yml`.

HONEST LIMITS, in descending order of how much they should worry you:

  1. It proves the values render. It does not prove the rendered manifest is what was
     meant. A renamed value that the chart now ignores renders fine and silently turns a
     feature off; only the subset the chart declared in its schema is caught. This is the
     same limit `release-secrets` documents for the keys inside a Secret.

  2. It renders the pinned version, so it cannot say a bump is safe before the bump
     exists. It catches an automated bump after it is proposed, which is the earliest
     point at which the answer is knowable.

  3. A `HelmRelease` taking values from `valuesFrom` is skipped out loud, because the
     referenced ConfigMap or Secret is not available offline. Rendering half the values
     and reporting clean would be worse than no gate, so the skip names the release and
     is repeated in the summary. No release uses it today.

  4. A version pin that is a semver range rather than an exact version is skipped out loud
     for the same reason: the gate would render a chart Flux might not pick. Every pin in
     this tree is exact.

  5. `helm template` is client-side. Nothing here asks the API server, so `make dry-run`
     still matters, and a chart that renders but whose CRD is absent from the cluster
     remains a live-cluster problem.

Usage: python3 tools/chart-values-check.py [repo-root]

Set CHART_CHECK_CACHE to a directory to keep pulled charts between runs.
"""

from __future__ import annotations

import os
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

try:
    import yaml
except ImportError:  # pragma: no cover - `make py-deps` guards this for the make path
    print("chart-values-check: PyYAML is missing - refusing to report clean", file=sys.stderr)
    sys.exit(2)

# Characters that make a version constraint a range rather than an exact pin.
RANGE_CHARS = ("x", "X", "*", ">", "<", "^", "~", "|")


def die(msg: str, code: int = 1) -> None:
    print(f"chart-values-check: {msg}", file=sys.stderr)
    sys.exit(code)


def run(cmd: list[str], timeout: int = 300) -> subprocess.CompletedProcess:
    return subprocess.run(cmd, capture_output=True, text=True, timeout=timeout)


def collect(root: Path):
    """Return (sources, releases) keyed by namespace+name, releases sorted by name."""
    sources: dict[tuple[str, str], dict] = {}
    releases: list[tuple[str, str, dict]] = []
    for path in sorted(root.glob("apply/**/*.yaml")):
        try:
            docs = list(yaml.safe_load_all(path.read_text()))
        except yaml.YAMLError as exc:
            die(f"{path} does not parse: {exc}")
        for doc in docs:
            if not isinstance(doc, dict) or not doc.get("kind"):
                continue
            meta = doc.get("metadata")
            if not isinstance(meta, dict) or not meta.get("name"):
                continue
            key = (meta.get("namespace", "default"), meta["name"])
            if doc["kind"] in ("HelmRepository", "OCIRepository"):
                sources[key] = doc.get("spec") or {}
            elif doc["kind"] == "HelmRelease":
                releases.append((key[0], key[1], doc.get("spec") or {}))
    return sources, sorted(releases, key=lambda r: r[1])


def resolve(ns: str, spec: dict, sources: dict) -> tuple[list[str], str, str]:
    """Return (helm pull argv, version, source url) for one HelmRelease, or die."""
    if "chartRef" in spec:
        name = spec["chartRef"].get("name", "")
        src = sources.get((ns, name))
        if src is None:
            die(f"{name}: chartRef names no HelmRepository or OCIRepository in the tree")
        url = src.get("url", "")
        ref = src.get("ref") or {}
        version = str(ref.get("semver") or ref.get("tag") or "")
        if not url.startswith("oci://"):
            die(f"{name}: chartRef source {url!r} is not OCI - not handled")
        return (["helm", "pull", url, "--version", version,
                 "--untar", "--untardir", "@DIR@"]), version, url

    chart = spec["chart"]["spec"]["chart"]
    version = str(spec["chart"]["spec"].get("version", ""))
    src_name = spec["chart"]["spec"]["sourceRef"]["name"]
    src = sources.get((ns, src_name))
    if src is None:
        die(f"{chart}: sourceRef {src_name!r} names no HelmRepository in the tree")
    url = src.get("url", "")
    if url.startswith("oci://"):
        return (["helm", "pull", f"{url.rstrip('/')}/{chart}", "--version", version,
                 "--untar", "--untardir", "@DIR@"]), version, url
    return (["helm", "pull", chart, "--version", version, "--repo", url,
             "--untar", "--untardir", "@DIR@"]), version, url


def main() -> int:
    root = Path(sys.argv[1] if len(sys.argv) > 1 else ".").resolve()
    if shutil.which("helm") is None:
        die("helm is missing from PATH - refusing to report clean", 2)
    if not (root / "apply").is_dir():
        die(f"{root} has no apply/ directory - refusing to report clean", 2)

    sources, releases = collect(root)
    if not releases:
        die("no HelmRelease found under apply/ - refusing to report clean", 2)

    cache = Path(os.environ.get("CHART_CHECK_CACHE") or tempfile.mkdtemp(prefix="chart-values-"))
    cache.mkdir(parents=True, exist_ok=True)

    failures: list[str] = []
    skips: list[str] = []
    checked = 0

    for ns, name, spec in releases:
        if spec.get("valuesFrom"):
            skips.append(f"{name}: uses valuesFrom, so its values are not available offline")
            continue

        argv, version, url = resolve(ns, spec, sources)
        if any(c in version for c in RANGE_CHARS):
            skips.append(f"{name}: pin {version!r} is a range, not an exact version")
            continue

        where = cache / name
        shutil.rmtree(where, ignore_errors=True)
        where.mkdir(parents=True, exist_ok=True)
        argv = [where if a == "@DIR@" else a for a in argv]

        try:
            pulled = run(argv)
        except subprocess.TimeoutExpired:
            failures.append(f"{name}: helm pull timed out")
            continue
        if pulled.returncode != 0:
            failures.append(f"{name} {version}: pull failed\n{indent(pulled.stderr.strip())}")
            print(f"FAIL {name:26s} {version} (pull)")
            continue

        chart_dirs = [p for p in where.iterdir() if p.is_dir()]
        if len(chart_dirs) != 1:
            failures.append(f"{name}: expected one untarred chart directory, found {len(chart_dirs)}")
            continue

        vfile = where / "values.yaml"
        vfile.write_text(yaml.safe_dump(spec.get("values") or {}, sort_keys=False))
        try:
            res = run(["helm", "template", spec.get("releaseName", name), str(chart_dirs[0]),
                       "-n", ns, "-f", str(vfile)])
        except subprocess.TimeoutExpired:
            failures.append(f"{name}: helm template timed out")
            continue
        checked += 1
        if res.returncode != 0:
            failures.append(f"{name} {version}: render failed\n"
                            f"{indent((res.stderr or res.stdout).strip())}")
            print(f"FAIL {name:26s} {version}")
        else:
            print(f"ok   {name:26s} {version:16s} via {url}")

    for s in skips:
        print(f"SKIP {s}")
    if skips:
        print("SKIP: these releases were NOT rendered - a clean result does not cover them")
    for f in failures:
        print(f"\n--- {f}")

    print(f"\nchart-values-check: {checked} of {len(releases)} HelmRelease(s) rendered, "
          f"{len(skips)} skipped, {len(failures)} failure(s)")
    print("chart-values-check: it proves the values render; it does not prove the rendered "
          "manifest is what was meant")
    return 1 if failures else 0


def indent(text: str, prefix: str = "    ") -> str:
    return "\n".join(prefix + line for line in text.splitlines())


if __name__ == "__main__":
    sys.exit(main())
