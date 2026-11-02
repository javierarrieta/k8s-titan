#!/usr/bin/env python3
"""traefik-exposure-check -- prove the Flux-managed Traefik would actually answer from outside.

Why this gate exists
--------------------
"The HelmRelease is Ready" is not the property anyone cares about. A Service whose `externalIPs`
list is empty, mis-named, or merged away by a valuesFrom mistake renders fine, applies fine, and
leaves the release `Ready=True` while nothing answers on 80/443. Every existing gate stays green
the whole way down. That is the same class of failure this repo keeps meeting -- an unmounted
blueprint, a stage that builds and is never listed, a release that reports health with a feature
silently off.

`make chart-values-check` proves the values RENDER. It never asks whether the rendered object is
the one the cutover was designed to produce. This does.

It also encodes the rule the API server enforced the hard way on 2026-11-02, when PR #211 merged
and stalled the cluster: `externalTrafficPolicy` may only be set on an externally-accessible
Service -- NodePort, LoadBalancer, or a non-empty `externalIPs`. That rejection is invisible to
`make dry-run`, because dry-run applies the HelmRelease object and `spec.values` is
`x-kubernetes-preserve-unknown-fields` in the Flux CRD, so the API server never sees the Service
the chart will render. Asserting the pairing here means the next person who splits those two
fields across phases hears about it on their laptop.

What it does NOT prove -- read this before trusting a pass
---------------------------------------------------------
* It renders the chart locally. It does not prove the live cluster accepted the result.
* It does not prove the address listed is really this node's address. It checks that one is
  present and that the pairing is legal; whether 37.187.159.156 is titan is a fact about OVH,
  checked with `kubectl get nodes -o wide` at cutover time, not here.
* It does not prove kube-proxy programs the DNAT, that the cloud provider does not filter the
  address, or that anything is listening once the pod starts.
* It reads `spec.values` only. A HelmRelease using `valuesFrom` would have values merged in that
  this script cannot see -- it fails loudly rather than guessing, see the check below.
"""

import ipaddress
import subprocess
import sys
import yaml
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
MANIFEST = ROOT / "apply" / "20-infra" / "traefik" / "traefik.yaml"
EXPECTED_NAMESPACE = "traefik-system"
EXPECTED_CLASS = "traefik"
EXPECTED_CONTROLLER = "traefik.io/ingress-controller"

failures: list[str] = []
notes: list[str] = []


def fail(msg: str) -> None:
    failures.append(msg)


def load_docs() -> list[dict]:
    if not MANIFEST.exists():
        print(f"traefik-exposure-check: FAIL - {MANIFEST} does not exist")
        sys.exit(1)
    docs = [d for d in yaml.safe_load_all(MANIFEST.read_text()) if d]
    if not docs:
        print("traefik-exposure-check: FAIL - manifest parsed to nothing; refusing to pass vacuously")
        sys.exit(1)
    return docs


def render(repo_url: str, chart: str, version: str, namespace: str, values: dict) -> list[dict]:
    tmp = Path("/tmp/traefik-exposure-values.yaml")
    tmp.write_text(yaml.safe_dump(values))
    cmd = [
        "helm", "template", "traefik", chart,
        "--repo", repo_url,
        "--version", version,
        "--namespace", namespace,
        "--values", str(tmp),
    ]
    proc = subprocess.run(cmd, capture_output=True, text=True)
    if proc.returncode != 0:
        print("traefik-exposure-check: FAIL - helm template failed; refusing to report clean")
        print((proc.stderr or proc.stdout).strip()[:1200])
        sys.exit(1)
    return [d for d in yaml.safe_load_all(proc.stdout) if d]


def main() -> int:
    docs = load_docs()
    hrs = [d for d in docs if d.get("kind") == "HelmRelease"]
    if len(hrs) != 1:
        print(f"traefik-exposure-check: FAIL - expected 1 HelmRelease, found {len(hrs)}")
        return 1
    hr = hrs[0]
    ns = hr.get("metadata", {}).get("namespace")
    if ns != EXPECTED_NAMESPACE:
        fail(f"HelmRelease namespace is {ns!r}, expected {EXPECTED_NAMESPACE!r}")

    spec = hr.get("spec", {})
    if spec.get("valuesFrom"):
        fail("HelmRelease uses valuesFrom; this gate cannot see merged values and will not guess. "
             "Update tools/traefik-exposure-check.py to resolve it, do not delete this check.")

    values = spec.get("values") or {}
    chart_spec = spec.get("chart", {}).get("spec", {})
    chart = chart_spec.get("chart", "")
    version = chart_spec.get("version", "")
    repo_name = chart_spec.get("sourceRef", {}).get("name", "")
    repos = {d["metadata"]["name"]: d["spec"]["url"] for d in docs if d.get("kind") == "HelmRepository"}
    if repo_name not in repos:
        print(f"traefik-exposure-check: FAIL - sourceRef {repo_name!r} not declared in this manifest")
        return 1

    objs = render(repos[repo_name], chart, version, ns, values)
    services = [o for o in objs if o.get("kind") == "Service"]
    if len(services) != 1:
        fail(f"expected exactly 1 rendered Service, found {len(services)}")
        return report()
    svc = services[0]["spec"]

    # --- the exposure itself ---
    if svc.get("type") != "ClusterIP":
        fail(f"Service type is {svc.get('type')!r}; the design is ClusterIP + externalIPs, "
             "and the chart default is LoadBalancer, which would silently ask for an address that "
             "will never be allocated")
    ext = svc.get("externalIPs") or []
    if not ext:
        fail("Service has NO externalIPs -- nothing outside the cluster can reach this Traefik. "
             "The release would still report Ready.")
    elif len(ext) != 1:
        fail(f"Service carries {len(ext)} externalIPs ({ext}); exactly one is intended")
    for addr in ext:
        try:
            ip = ipaddress.ip_address(addr)
        except ValueError:
            fail(f"externalIPs entry {addr!r} is not a valid IP address")
            continue
        # A private or loopback address here is legal YAML, a legal Service, and a Ready release that
        # nothing outside the cluster can reach -- the same silent shape as an empty list. Found by
        # negative-testing this gate: swapping the node address for 10.0.0.5 passed cleanly.
        if ip.is_private or ip.is_loopback or ip.is_link_local:
            fail(f"externalIPs entry {addr!r} is not publicly routable ({ip.__class__.__name__}); "
                 "kube-proxy will happily program it and no external client will ever arrive")

    # --- the API server rule that stalled the cluster on 2026-11-02 ---
    etp = svc.get("externalTrafficPolicy")
    externally_accessible = svc.get("type") in ("LoadBalancer", "NodePort") or bool(ext)
    if etp and not externally_accessible:
        fail(f"externalTrafficPolicy={etp!r} on a Service that is not externally accessible -- "
             "the API server rejects this and the HelmRelease will go InstallFailed, which holds "
             "stage-infra and everything downstream of it (PR #214)")
    if ext and etp != "Local":
        fail(f"Service has externalIPs but externalTrafficPolicy={etp!r}, not 'Local' -- source "
             "IP is SNATed away, which is half the reason this exposure mechanism was chosen")

    # --- the class claim: without it the address answers and routes nothing ---
    classes = [o for o in objs if o.get("kind") == "IngressClass"]
    if not classes:
        fail("no IngressClass rendered -- the new Traefik would own the address but claim no routes, "
             "so every host 404s while the release reports Ready")
    else:
        ic = classes[0]
        if ic["metadata"]["name"] != EXPECTED_CLASS:
            fail(f"IngressClass is {ic['metadata']['name']!r}; every live Ingress names {EXPECTED_CLASS!r}")
        if ic.get("spec", {}).get("controller") != EXPECTED_CONTROLLER:
            fail(f"IngressClass controller is {ic.get('spec', {}).get('controller')!r}")
        if ic["metadata"].get("annotations", {}).get("ingressclass.kubernetes.io/is-default-class") != "true":
            notes.append("IngressClass is not marked default; fine if every Ingress names it explicitly")

    # --- publishedService must be on together with the address ---
    deps = [o for o in objs if o.get("kind") == "Deployment"]
    args = deps[0]["spec"]["template"]["spec"]["containers"][0].get("args", []) if deps else []
    published = [a for a in args if "publishedservice" in a.lower()]
    if ext and not published:
        fail("externalIPs set but --providers.kubernetesingress.publishedservice is absent: every "
             "Ingress .status keeps the old address while the new Traefik is the real path")
    if published and not ext:
        fail(f"{published[0]!r} is set with no externalIPs: every Ingress .status would be rewritten "
             "to a ClusterIP that no client can reach")

    return report(len(objs))


def report(count: int = 0) -> int:
    for n in notes:
        print(f"traefik-exposure-check: note - {n}")
    if failures:
        for f in failures:
            print(f"traefik-exposure-check: FAIL - {f}")
        print("traefik-exposure-check: refusing to report clean")
        return 1
    print(f"traefik-exposure-check: ok - {count} rendered objects; ClusterIP carrying the node "
          "address, externalTrafficPolicy Local, IngressClass claimed, publishedService paired")
    print("traefik-exposure-check: note - this renders; it does not prove the live cluster accepted "
          "it, nor that the address is this node's. Check `kubectl get nodes -o wide` at cutover.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
