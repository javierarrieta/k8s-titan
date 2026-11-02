# #209 — cutover titan from k3s' bundled Traefik to a Flux-managed Traefik — implementation plan

**Date:** 2026-10-31.
**Design:** `docs/superpowers/specs/2026-10-31-titan-ingress-ownership-decision.md` — read it first.
That file holds the decision (**D, adopted**), the elimination of MetalLB (§2), the four mandatory
pre-flight checks (§8), and the "what a replacement must reproduce" list (§6). This plan is the
executable half; where it restates a measurement it is because the ticket cannot be executed without
it, otherwise it cites the spec or the pre-flight.
**Pre-flight research:** `review/209-preflight-findings.md` — five questions answered with sources.
Anything it marks **SO-UNVERIFIED** is an open risk in this plan, not a settled fact; §2 resolves each
one with a command.
**Repos:** `titan/` = `k8s-titan` (this repo), `nix/` = `nixos-configurations`.
**Base:** `titan origin/main@a6e985e`. Re-verify before the first commit.
**Cluster:** single-node k3s `v1.35.8+k3s1` on NixOS. Public address is the node's own primary
address, statically configured on `eno1` with a /24 and an on-link gateway
(`nix/hosts/titan/configuration.nix:80`). Written throughout as `<TITAN_PUBLIC_IP>` — this repo is
public and AGENTS.md forbids a concrete public IPv4 in a committed file.

---

## 0. What is decided — do not re-litigate

**Option D: a Flux-managed Traefik `HelmRelease`, exposed as a `ClusterIP` Service with
`externalIPs`, with both `traefik` and `servicelb` disabled in k3s.** Adopted 2026-10-31 by the
operator. Option A (keep ServiceLB) was offered as the lower-risk alternative and **declined**.
MetalLB was eliminated on evidence and is not a candidate: titan's public IP is already configured on
`eno1`, so there is nothing for L2 ARP mode to answer for, and BGP is irrelevant on one node. Spec §2.

What D commits to, and what is therefore **out of scope for this plan to reconsider**:

- `nix/hosts/titan/vars.nix` becomes `disable = [ "traefik", "servicelb" ]`. That fully reverses
  `nix` spec D4, not half-preserves it. §5 says the sentence the PR owes.
- The Traefik `Service` is Flux-owned, `type: ClusterIP`, with `externalIPs` naming the node's own
  address. **No `helm.sh/resource-policy: keep` on it** — see T2 for why that annotation is a black
  hole here rather than a safety net.
- **`externalTrafficPolicy: Local`**, chosen deliberately rather than inherited from the VPS manifest
  (which says `Cluster` and therefore SNATs). Spec §5.3, §7b.
- The two NodePorts disappear. The firewall allow-list shrinks to 80/443 — and §5 shows it already
  *is* 80/443, so this is a comment change, not a rule change.
- `externalIPs` is a **deprecated upstream Service mechanism** and this plan adopts it as a permanent
  design. Spec §3 and pre-flight Q3.2 both say so; the fleet precedent is the VPS, where it has run
  for a year. Saying "we know" is the requirement, not re-arguing it.

### 0.1 The chart pin — and one corrected assumption

**Pin: chart `41.1.1`, `image.repository: rancher/mirrored-library-traefik`, `image.tag: "3.7.8"`.**

**The pre-flight's parity pin was wrong and this is the correction, written down so nobody re-derives
it.** Q5.8 proposed upstream chart `40.1.0` as the parity pin for k3s's `40.1.4+up40.1.0` + Traefik
3.7.8, at medium confidence. Measured, that pairing **cannot render**. Chart 40.1.0 ships
`templates/requirements.yaml`, which reads `.Chart.Annotations["traefik.io/proxy-max-version"]` —
`v3.7.1` for that chart — and hard-fails:

```
Error: execution error at (traefik/templates/requirements.yaml:9:8):
ERROR: This version of the Chart only supports Traefik Proxy up to v3.7.1.
```

Rancher's `40.1.4+up40.1.0` repackaging is the only reason the pairing works on the bundled install;
upstream cannot reproduce it. Measured `proxy-max-version` by chart: `40.1.0`/`40.2.0` → `v3.7.1`,
`41.0.2` → `v3.7.6`, `41.1.0`/`41.1.1` → `v3.7.9`, `42.2.0` → `v3.7.16`. **No upstream chart has
appVersion 3.7.8 at all.** So 41.1.1 is not a conservative choice over a neutral alternative — it is
the floor, the minimum chart move that can render 3.7.8 at all.

| option | chart | proxy | verdict |
|---|---|---|---|
| **A** | 41.1.1 | 3.7.8 (pinned, rancher mirror) | **adopted.** The cutover already changes five things: controller ownership, exposure mechanism, `externalTrafficPolicy`, dashboard state, and namespace. A proxy bump would be a sixth simultaneous change, and a regression could not be attributed to the plumbing or to Traefik. Same image also means it is already pulled on the node — no image pull inside an outage window that is real downtime for 15 hostnames. |
| B | 41.1.1 | 3.7.9 (chart default) | **rejected.** Changes the proxy patch version *and* the registry (rancher mirror → `docker.io/library/traefik`) while gaining nothing over A. Two changes for no benefit. |
| C | 42.2.0 | 3.7.16 (chart default) | **deferred, not dismissed.** Version currency is a maintenance goal, not a cutover goal. 3.7.8 → 3.7.16 should be its own PR with its own rollback, landed after the cutover is proven stable. The pin is reversible by editing two values keys. |

**A second values-shape trap on the same axis, and it is the reason `make chart-values-check` is a
mandatory gate here.** Between 40.x and 41.x the logging keys moved: 40.1.0 has a top-level `logs:`
block (`logs.general`, `logs.accessLog`); 41.0.2 onward have top-level `log:` and `accessLog:`.
Because the chart's `values.schema.json` sets `schemaRoot.additionalProperties: false` — measured,
and so are the sub-blocks `api`, `ingressClass`, `ports`, `providers`, `image`, `rbac`,
`serviceAccount`, `hub`, `autoscaling`, `core`, `tracing`, `podDisruptionBudget`, the probes and
`accessLog.filters` — a stale key is a **render failure, not a silent no-op**:

```
Error: values don't meet the specifications of the schema(s) ...
traefik: - at '': additional properties 'logs' not allowed
```

That is the good outcome. The bad one, documented in `../k8s-techdelivery/apply/20-infra/traefik-ingress.yaml`,
is that chart 41.x *silently ignores* the old top-level `service.type` / `service.externalIPs` keys
and renders `type: LoadBalancer` with no error. So: **everything goes under `service.spec`.**

---

## 1. How to work a task

Every task carries the same five blocks, and they are not decoration.

- **Files:** the exact paths created or edited. A task that cannot name its files is not scoped.
- **Copy:** how state moves, if any. `n/a` for stateless.
- **Exit:** one observable command and the output that proves it. Every gate in this repo is static;
  none of them can tell you that traffic actually flows.
- **Rollback:** the artifact and the command. Detailed per phase in §6.
- **Gates:** `make check` where the age key and network are available; otherwise `make check-ci`, and
  the PR records which one ran. `chart-values-check` is in `check` but not `check-ci` (it needs
  network). `dry-run` is in neither and must be run explicitly.

### 1.1 The two things that can take the cluster down

Everything else in this plan is bookkeeping. These two are not.

**(1) `--disable=traefik` uninstalls the CRDs, and the repo gates cannot see it.**
k3s resolves `--disable=<name>` against the **basename of the bundled manifest file**, not a
HelmChart name. At `v1.35.8+k3s1`, `manifests/traefik.yaml` declares **two** HelmCharts in one file
— `traefik-crd` and `traefik` — so there is no way to disable one without the other. Deleting a
`HelmChart` makes helm-controller run a real `helm uninstall`. If the 25 `traefik.io`/`hub.traefik.io`
CRDs go with the `traefik-crd` release, every `Middleware` and `IngressRouteTCP` is
cascade-deleted — **while `crd-check` and `ingress-auth` stay green, because both read
`vendor/traefik-crds/` in this repo rather than the cluster.**

**The escape hatch, and the finding that decides how it must be used.** helm-controller's
`shouldManage()` returns false when a HelmChart carries `helmcharts.helm.cattle.io/unmanaged`, and
that single predicate gates **both** `OnChange` and the scoped `OnRemove` handler
(`RegisterScopedOnRemoveHandler(... c.shouldManage ...)`), so no uninstall Job is created at all.
That upgrades the pre-flight's "medium confidence" to source-verified intent — but it is still the
intent of a version this workspace cannot run, so **P4 proves it on a scratch cluster before anything
touches titan.**

**And the trap inside the trap: annotating the live CRDs with `helm.sh/resource-policy: keep` does
nothing.** Helm's `filterManifestsToKeep` (`pkg/action/resource_policy.go`, v4.3.0) reads the
annotation from `m.Head.Metadata.Annotations` — the **stored release manifest**, i.e. what the chart
rendered at install time. It never looks at the live object. So the annotation protects a resource
only when it is in the chart's own output (which is why a chart that renders it onto a Service is a
different case from putting it on the live CRDs by hand, and why T2 declines to render it onto *our*
Service at all — see the comment on `service:` there). This also
disposes of the pre-flight's "contradiction" about helm#10890: it is not a bug to design around, it
is the design. **P1 is therefore a check on the old chart's rendering, not a knob we can turn.**

**(2) The IngressClass handover.** The upstream chart defaults `ingressClass.name` to the release
fullname. If the old chart is uninstalled before a new `IngressClass` named `traefik` exists, every
`ingressClassName: traefik` Ingress is unserved in the gap. The mirror-image failure is just as real:
two Helm releases cannot both own an object named `traefik`, so installing the new one first fails on
`AlreadyExists`. §4 phase C3 resolves it with Helm's own adoption rule, quoted in full there.

### 1.2 What is actually served today, and what must still work afterwards

Built from this tree (`kubectl kustomize apply/50-apps apply/60-tesla`), 2026-10-31:

| | object | namespace | note |
|---|---|---|---|
| Middleware | `teslamate-auth` | `apps` | referenced as `apps-teslamate-auth@kubernetescrd` by `tesla`, `tesla-boards`, `investing-agent` |
| Middleware | `bearer-auth` | `llm` | `llm-bearer-auth@kubernetescrd` |
| Middleware | `grafana-auth` | `observability` | `observability-grafana-auth@kubernetescrd` |
| IngressRouteTCP | `tesla-telemetry` | `apps` | `entryPoints: [websecure]`, `tls.passthrough: true`, host `telemetry.titan.arrieta.eu` |

15 `Ingress` objects live on titan, carrying **14 distinct hostnames**, plus `telemetry` over the
IngressRouteTCP = **15 hostnames served**: `auth`, `authorize`, `coder`, `collabora`, `files`, `grafana`,
`investing-agent`, `llm`, `meals`, `open-webui`, `streaming`, `sure`, `tesla`, `tesla-boards`, `telemetry`
(`tesla` is carried by two Ingress objects). **That list is a snapshot of a 2026-10-31 live read, not a
list to copy.** C4 and §7.2 both re-derive it from `kubectl get ingress -A` at run time, and so must any
later execution of this plan — a typed list goes stale silently, and it already did once.

Two things to note honestly:

- **This tree builds only 13 of the 15 Ingress objects, and that is not drift.** The two the tree does not
  build are `auth/authentik-server` (`auth.titan`) and `sure/sure` (`sure.titan`), both rendered by their
  `HelmRelease` at deploy time — `apply/50-apps/auth/authentik.yaml` and `apply/50-apps/sure/sure.yaml`.
  `kustomize build` cannot see inside a `HelmRelease`, so counting Ingresses in the built tree
  **systematically undercounts the blast radius by every chart-rendered Ingress.** Any future count of
  affected hostnames must come from `kubectl get ingress -A`, not from the tree. Verified 2026-10-31 by
  diffing the built tree against the live cluster.
- Every `router.middlewares` reference in this tree is **same-namespace** (`apps-*` from `apps`,
  `llm-*` from `llm`, `observability-*` from `observability`), so
  `providers.kubernetesCRD.crossProviderNamespaces` can stay unset. The VPS warns that tightening it
  silently drops cross-boundary auth; titan has no cross-boundary reference to drop, and P2c proves
  that rather than trusting this table.
- `streaming.titan.arrieta.eu` uses `tesla-streaming-tls`, not the wildcard, because TeslaMate's
  Erlang client rejects wildcard SANs. AGENTS.md calls that a deliberate exception. It is unaffected
  by this cutover — the Secret is namespace-local to `apps` and Traefik reads it from there — but it
  is the one host where a "TLS broke" report is most likely to be misdiagnosed.

---

## 2. Wave 0 — pre-flight. Nothing downstream is worth starting until every row is GREEN

Each task is read-only against titan unless stated. Use the `k8s-reader` ServiceAccount
(`docs/agent-read-access.md`) except where a row says it cannot. **Two rows need an admin context:**
anything that runs `helm` (`helm list`, `helm uninstall`) reads Helm release records, which are
**Secrets**, and `apply/20-infra/k8s-reader/clusterrole.yaml` deliberately omits `secrets`. Those rows
are marked **admin context required**, the same way §7.1 marks `dry-run`.

### P1 — do the live CRDs carry `helm.sh/resource-policy: keep`, and who owns them?

This is the check that decides whether orphaning is mandatory or merely prudent. Spec §8.1.

- **Files:** none — read-only.
- **Copy:** n/a.
- **Exit:**

  ```bash
  kubectl get crd middlewares.traefik.io \
    -o jsonpath='{.metadata.annotations}{"\n"}{.metadata.ownerReferences}{"\n"}'
  kubectl get crd -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.metadata.labels.helm\.sh/resource-policy}{"\t"}{.metadata.labels.app\.kubernetes\.io/managed-by}{"\n"}{end}' \
    | grep -E 'traefik\.io|hub\.traefik\.io'
  ```

  **PASS (expected):** no `helm.sh/resource-policy` anywhere, `managed-by: Helm`, no
  `ownerReferences`, and exactly **25** rows. That is the dangerous result: it means the old chart's
  rendered manifest does not carry the keep annotation, so `helm uninstall` **will** delete them, and
  the only surviving protection is P4's `unmanaged` proof.
  **PASS (lucky):** every CRD already carries `helm.sh/resource-policy: keep`. Then the old chart
  rendered it, the annotation is in the stored manifest, and the uninstall is survivable — but P4 is
  still run, because a keep-annotated CRD is still *deleted from the release* and left unmanaged, and
  the IngressClass hazard is untouched either way.
  **FAIL:** anything that names an `ownerReference` to a namespaced object, or a CRD count other than
  25. Re-read before proceeding; the model in this plan is wrong.
- **Gates:** none (read-only).

**Do not "fix" a PASS-expected result by adding the annotation to the live CRDs.** §1.1 explains
why: helm reads it from the stored manifest, never from the live object.

### P2 — enumerate what the old release owns, and what the cluster actually serves

- **Files:** none — read-only.
- **Copy:** n/a.
- **Exit:** every sub-check returns, and the answers are pasted into the #209 thread.

  **P2a — the release records and their cluster-scoped objects.** **Admin context required** —
  `helm list` reads release records, which are Secrets, and `k8s-reader` cannot read Secrets.
  ```bash
  helm list -A
  kubectl get ingressclass -o wide
  kubectl get clusterrole,clusterrolebinding -o name | grep -i traefik
  # the finalizer C4 has to clear if the Service sticks in Terminating (§8.11)
  kubectl -n kube-system get svc traefik -o jsonpath='{.metadata.finalizers}{"\n"}'
  ```
  Expected: releases `traefik` and `traefik-crd` in `kube-system`; exactly one `IngressClass` named
  `traefik`; ClusterRole/Binding named `traefik-kube-system` (the chart bakes the release namespace
  into the name via `traefik.clusterRoleName`). **That naming is why the new release can live in a
  different namespace without an RBAC collision** — verified by rendering 41.1.1 in
  `traefik-system`, which produces `traefik-traefik-system`. The IngressClass is the **only**
  cluster-scoped collision between old and new.

  **P2b — reconcile the live Ingress count against this tree.**
  ```bash
  kubectl get ingress -A --no-headers | wc -l
  kubectl get ingress -A -o custom-columns=NS:.metadata.namespace,NAME:.metadata.name,\
  CLASS:.spec.ingressClassName,TLS:.spec.tls[0].secretName
  ```
  This tree builds 13; the live count is **15** (§1.2). The two the tree cannot see are chart-rendered.
  **PASS:** `wc -l` prints **15**, and the two objects not built by the tree are
  `auth/authentik-server` and `sure/sure`, both `class: traefik`.
  **FAIL:** any other count, or any extra object that is not one of those two — an Ingress nobody
  listed is an Ingress whose routing state this plan has not accounted for.

  **P2c — prove no cross-namespace CR reference exists.**
  ```bash
  *Do not grep a rendered annotation map.* `kubectl` prints a map as Go `map[k:v k2:v2]` — **no space
  after the colon** — so `grep -o 'middlewares: [^ ]*'` (colon + space) matches nothing, ever, and the
  check would pass vacuously on an empty set. Parse the JSON instead, and make the pass condition a
  **count**, so it cannot be satisfied by finding nothing:

  ```bash
  # Ingress-side refs
  kubectl get ingress -A -o json | python3 -c "
  import json,sys
  for it in json.load(sys.stdin)['items']:
      ns = it['metadata']['namespace']
      mw = it['metadata'].get('annotations',{}).get(
          'traefik.ingress.kubernetes.io/router.middlewares','')
      if mw: print(ns, mw)
  " | sort -u

  # CR-side refs: where a cross-namespace reference would actually live, and which the
  # Ingress-side check never reads.
  kubectl get ingressroute,ingressroutetcps -A -o json | python3 -c "
  import json,sys
  for it in json.load(sys.stdin)['items']:
      ns = it['metadata']['namespace']
      for r in it['spec'].get('routes', []):
          for m in r.get('middlewares', []):
              print(ns, m.get('namespace','<same>'), m.get('name'))
  "
  ```
  **PASS:** the first command prints **exactly 5 non-empty lines** (matching the 5 references in the
  tree), and on every line the reference's namespace prefix — the text before the first `-`, up to
  `@kubernetescrd` — equals the namespace in column 1. The second command prints nothing, or only
  lines whose namespace column is `<same>` or equal to column 1.
  **FAIL:** zero lines (finding nothing is not the same as finding nothing to fail), a count other
  than 5, or a line whose prefix differs →
  `providers.kubernetesCRD.crossProviderNamespaces` must name the source namespace in the new values,
  or that host silently loses its gate.

  **P2d — the CR dump, taken now so it exists before anything can need it.**
  ```bash
  kubectl get middleware,middlewaretcp,ingressroute,ingressroutetcps,ingressrouteudp,\
  traefikservice,tlsoption,tlsstore,serverstransport,serverstransporttcp \
    -A -o yaml > /tmp/traefik-cr-dump-$(date +%F).yaml
  ```
  Untracked (`/tmp`), because a dump of live objects is not a committed manifest.
- **Gates:** none (read-only).

### P3 — kube-proxy mode, who holds host 80/443, and which helm the uninstall Job uses

Spec §8.2 and §8.4.

- **Files:** none — read-only, plus one command on the host.
- **Copy:** n/a.
- **Exit:**

  **P3a — proxy mode.** k3s hardcodes `proxy-mode: iptables` in
  `pkg/daemons/agent/agent_linux.go`; kube-proxy runs in-process, so there is no DaemonSet to read and
  `pgrep -af kube-proxy` matches nothing — which is why the check must first prove it read a command
  line at all, or it passes vacuously on an empty result.
  ```bash
  ps -o args= -C k3s | tr ' ' '\n' | grep -c .                       # must be non-zero
  ps -o args= -C k3s | tr ' ' '\n' | grep -i 'proxy-mode' || echo "NO proxy-mode flag"
  ```
  **PASS:** the first command prints a **count greater than zero** (the k3s process was found and its
  arguments were actually read), **and** the second prints either `NO proxy-mode flag` — meaning k3s
  is using its hardcoded default, `iptables` — or `--proxy-mode=iptables`.
  **FAIL:** the first command prints `0` (wrong host, or k3s is not the process name — the check read
  nothing and must not be treated as a pass), or the second prints `--proxy-mode=nftables` or
  `--proxy-mode=ipvs`. The externalIPs analysis in this plan is iptables-specific; nftables mode
  additionally installs **no** firewall-accept rules for service ports, so §7's off-node proof becomes
  mandatory rather than confirmatory and the firewall section must be re-read.

  **P3b — who holds host 80/443, and nothing else.**
  ```bash
  sudo ss -lntp | grep -E ':80 |:443 '
  kubectl -n kube-system get ds,pod -o wide | grep svclb-
  kubectl get pods -A -o json | python3 -c "import json,sys
  for p in json.load(sys.stdin)['items']:
      for c in p['spec']['containers']:
          for hp in (c.get('ports') or []):
              if hp.get('hostPort') in (80,443): print(p['metadata']['namespace'],p['metadata']['name'],hp['hostPort'])"
  ```
  **PASS:** the only hostPort holders are the `svclb-traefik-*` pods.
  **FAIL:** anything else wants 80/443 — spec §8.4 is not satisfied and the cutover cannot proceed.

  **P3c — the helm version the uninstall Job will use.** **Admin context required.** You cannot read
  the bundled helm version off a `klipper-helm` image *tag*, so do not try: ask the image itself.
  ```bash
  # 1. the image the uninstall/install Jobs actually use
  kubectl -n kube-system get jobs -o jsonpath=\
    '{range .items[*]}{.metadata.name}{"\t"}{.spec.template.spec.containers[0].image}{"\n"}{end}'
  # 2. ask that image. --command overrides the entrypoint so this is a read-only version print.
  kubectl -n kube-system create job helm-probe --command --image=<the klipper-helm image from step 1> \
    -- helm version --short
  kubectl -n kube-system logs job/helm-probe
  kubectl -n kube-system delete job helm-probe
  ```
  **PASS:** the log line contains `v4.` (klipper-helm master pins `HELM_VERSION=v4.1.4`). Helm v4
  matters twice: `filterManifestsToKeep` reads the stored manifest (§1.1) and
  `verifyOwnershipBeforeDelete` skips objects the release no longer owns — which is what makes the C3
  handover safe in both directions.
  **FAIL:** the log line contains `v3.` — then assume the old release **will** delete the IngressClass
  on uninstall, and use C3's fallback.
  **UNKNOWN:** no Job exists to read an image from. Take the image from the scratch cluster's Job spec
  in P4 instead, and until this returns a version treat it as UNKNOWN — which makes C4's old-release
  uninstall conditional (see C4).
- **Gates:** none (read-only).

### P4 — scratch-cluster proof that `unmanaged` actually suppresses the uninstall

**This is the highest-value task in the plan and it is not optional.** Everything in §4 assumes that
annotating both HelmCharts `unmanaged` prevents helm-controller from running the uninstall Job. The
pre-flight rated that medium confidence because upstream documents the annotation as "the chart is
not updated", not "not uninstalled". The source reading in §1.1 says the predicate gates `OnRemove`
too — but it is a reading of `master`, and titan runs a pinned build.

- **Files:** none in git. A scratch k3s at **exactly `v1.35.8+k3s1`** (the version is load-bearing:
  the two-HelmCharts-in-one-file layout is what makes this a hazard at all).
- **Copy:** n/a.
- **Exit:** all four assertions hold.

  1. Bring up k3s with defaults; confirm `traefik` and `traefik-crd` HelmCharts and 25 traefik CRDs.
     ```bash
     kubectl get helmchart -n kube-system
     kubectl get crd --no-headers | grep -cE 'traefik\.io|hub\.traefik\.io'
     ```
  2. Create a `Middleware` in a non-`kube-system` namespace so a cascade is observable.
  3. Annotate **both** charts, then disable the add-on the way titan will (flip `--disable=traefik
     --disable=servicelb` and restart, not just `kubectl delete helmchart`):
     ```bash
     kubectl -n kube-system annotate helmchart traefik     helmcharts.helm.cattle.io/unmanaged=true --overwrite
     kubectl -n kube-system annotate helmchart traefik-crd helmcharts.helm.cattle.io/unmanaged=true --overwrite
     ```
  4. **PASS:** after the restart, the HelmChart objects are gone, **no uninstall Job ever appears**
     (`kubectl -n kube-system jobs` and `kubectl get events | grep -i uninstall`), the Traefik
     Deployment and Service still exist, all 25 CRDs still exist, and the `Middleware` still resolves.
     **FAIL:** a Job appears, or the CRDs or the `Middleware` disappear. Then §4 must be re-sequenced
     around the fallback in §6.C1 — **do not improvise on titan.**
  5. Also record, on the scratch cluster, whether the `unmanaged` annotation survives the k3s restart.
     k3s re-applies bundled manifests through an `Addon` + checksum skip and does not re-create an
     unchanged file, and it applies with its own field manager, so a `kubectl annotate` should
     survive — but "should" is exactly what this task exists to replace.
- **Gates:** none (scratch cluster).

### P5 — chart and proxy pin — **✅ DONE 2026-10-31**

Resolved in §0.1: chart `41.1.1`, `rancher/mirrored-library-traefik:3.7.8`, with the 40.1.0
parity-pin assumption recorded as disproved and options B and C rejected on the record.

Two extra measurements from the same pass, both load-bearing later:

- **41.1.1's `crds/` holds exactly 25 files: 15 `hub.traefik.io_*` + 10 `traefik.io_*`, and no
  `gateway-standard-install.yaml`.** Chart 40.1.0 *did* ship Gateway API CRDs there; 41.1.1 does
  not. That matters because Flux re-applies `crds/` on upgrade and the
  `safe-upgrades.gateway.networking.k8s.io` ValidatingAdmissionPolicy refuses a Gateway API
  downgrade — the failure that made the VPS's Traefik un-upgradeable for six hours (VPS finding F20,
  `../k8s-techdelivery/apply/20-infra/traefik-ingress.yaml`). **Pinning 41.1.1 sidesteps F20
  entirely.**

  **Do not read "25 == 25" as "same files".** The live count from P1 and this file count are a
  **COUNT match only**. A count cannot show that the 25 live CRDs are the same 25 kinds, nor that
  their **contents** agree, and the live set was installed by the k3s `traefik-crd` chart, not by
  41.1.1. Orphan-and-reuse is the right strategy because the CRDs are **cluster-scoped and shared**
  and a cascade would delete every `Middleware` and `IngressRouteTCP` (§1.1) — not because the counts
  line up. The contents question is settled separately, by T1 vendoring 41.1.1's `crds/` and by the
  explicit post-cutover `kubectl apply` in C6, which is an apply of known files rather than an
  inference from a count.
- `providers.kubernetesCRD.allowCrossNamespace` still exists in 41.1.1 alongside the newer
  `crossProviderNamespaces` (which requires Traefik v3.7.1+). Both default permissive-when-unset.
  Per P2c, leave both unset.

- **Rollback:** n/a — read-only. **Gates:** none.

### P6 — `externalTrafficPolicy` on the externalIPs path — source-resolved, confirm live

The pre-flight left this SO-UNVERIFIED because upstream docs frame the field around NodePort and
LoadBalancer. It is now settled from source, for iptables mode specifically:

- `pkg/apis/core/validation/validation.go` gates `externalTrafficPolicy` on
  `ExternallyAccessible()`, and `pkg/api/service/utils.go` defines that as LoadBalancer **or**
  NodePort **or** (`ClusterIP && len(ExternalIPs) > 0`). So the field is **legal** on a
  ClusterIP+externalIPs Service — and in fact required to be non-empty once the Service is
  externally accessible, which is another reason to set it explicitly rather than rely on defaulting.
- `pkg/proxy/iptables/proxier.go` programs externalIPs by jumping them to the *external traffic*
  chain (`usesExternalTrafficChain := hasEndpoints && svcInfo.ExternallyAccessible()`), and that
  chain's endpoint selection and masquerade behaviour are chosen by `svcInfo.ExternalPolicyLocal()`.
  So **`Local` is honoured on the externalIPs path in iptables mode.**

Two caveats that survive the source reading and that §7 must therefore check empirically:

1. The same code masquerades **locally-originated host** traffic to an externalIP even under `Local`
   ("masquerade LOCAL traffic for … external destinations"), and short-circuits pod → externalIP
   traffic to the cluster policy chain. So a curl **from titan itself** will never show the real
   client IP. The verification must come from a machine that is neither the node nor a pod on it.
2. `Local` drops traffic when there are no node-local ready endpoints. On one node that is a no-op
   today and a total black hole the day a second node appears or the Traefik pod is unschedulable.
   That footgun is accepted, not overlooked — record it in the runbook.

- **Files:** none. **Copy:** n/a. **Rollback:** n/a.
- **Exit:** P3a is `iptables`. The live confirmation is §7's off-node curl.
- **Gates:** none.

### P7 — the host firewall is not authoritative; do not touch it

- **Files:** none.
- **Exit:** `nix` keeps `networking.firewall` on with 80/443/13491 open and **no firewalld**. Confirm
  nothing in the cutover enables one. kube-proxy's iptables rules and a product firewall do not
  cooperate — a k3s maintainer states outright that k3s with firewalld is unsupported, and NixOS users
  report kube-proxy's rules bypassing the module-managed firewall entirely. **Behaviour is proven
  from off-node (§7), never by reading rules.**
- **Rollback:** n/a. **Gates:** none.

---

## 3. Wave 1 — the repo work. Four PRs across two repos, none of which moves traffic on its own

§5 gives the landing order and the reason for it. The four are: **PR 1** titan phase-A HelmRelease
(installs, serves nothing), **PR 2** titan phase-B values (this is the one that moves traffic, and it
only moves it in the C4 window), **PR 3** `nixos-configurations` disable flags, **PR 4** titan
CRD re-vendor plus documentation. T1–T3 below are the work; they do not map one-to-one onto the PRs,
because T2 is split across PR 1 and PR 2 and T1 lands in PR 4.

### T1 — vendored Traefik CRDs: sufficient as-is, refresh **after** the cutover

**Verdict: `vendor/traefik-crds/` is sufficient for the gate as written, and must be re-vendored
after C4, not before.**

- **Files:** `vendor/traefik-crds/{middlewares.yaml,ingressroutetcps.yaml,VERSION}` — touched in a
  post-cutover PR only.
- **Copy:** n/a.
- **Why it is sufficient.** `crd-check` validates built objects against vendored schemas, and the only
  Traefik kinds this tree authors are `Middleware` and `IngressRouteTCP` — which are exactly the two
  files `scripts/update-crds.sh` vendors. Adding the other 23 schemas would validate nothing, because
  no manifest in this repo uses those kinds. The vendored set is scoped to what is checked, and that
  is the right shape.
- **Why it must still be refreshed.** The current files were vendored from the live cluster on
  **2026-10-19**, i.e. from the CRDs the k3s `40.1.4+up40.1.0` chart installed. After the cutover the
  CRDs are the ones 41.1.1's `crds/` would install (or, under orphan-and-reuse, the same objects
  surviving — which is the point of C1). Either way, re-vendoring is what proves the vendored schema
  and the enforced schema agree:
  ```bash
  make update-crds            # scripts/update-crds.sh, k8s-reader context, laptop-only
  make crd-check
  ```
  The script's own header explains why it reads the API server rather than an upstream tag: Traefik
  ships CRDs inside a release tarball, so "the version upstream" and "the version that will reject
  our manifest" are different objects.
- **The permanent consequence, and one correction to the pre-flight.** Helm never upgrades or deletes
  CRDs installed from a chart's `crds/` directory — install-once, by design (pre-flight Q5.5). **Flux
  does**, if you let it: the helm-controller has its own CRD policy — `spec.install.crds` and
  `spec.upgrade.crds`, each one of `Skip | Create | CreateReplace`, confirmed present in
  `vendor/flux-crds/helmreleases.yaml`. **This HelmRelease sets both to `Create`.** That is a
  deliberate departure from `apply/20-infra/cert-manager/cert-manager.yaml`, which uses
  `upgrade.crds: CreateReplace`, and the reason is the cutover window: with `CreateReplace`, the C3
  *upgrade* would replace the 25 live 40.1.4-era CRDs with 41.1.1's as a side effect of a values
  change — a live, cluster-scoped mutation landing mid-cutover, on the objects every `Middleware` and
  `IngressRouteTCP` depends on, at the exact moment the IngressClass is being handed over. `Create`
  installs what is missing and touches nothing that exists, which is the whole point of
  orphan-and-reuse: the CRDs survive untouched and the release adopts them.

  **So CRD refresh stays an explicit, separate, post-cutover action** — `kubectl apply` of the
  vendored 41.1.1 `crds/`, in C6, with its own check and its own rollback — rather than something that
  rides invisibly on a chart bump. When a later PR bumps the chart it may move this HelmRelease to
  `CreateReplace`, but only after the schemas have been diffed and vendored, and never in the same
  change as the cutover.
- **Exit — and what it is actually testing.** This exit tests **one** behaviour: that the cutover left
  the live CRD schemas byte-identical, which is what `upgrade.crds: Create` promises and what
  orphan-and-reuse depends on. It does **not** test that 41.1.1's schemas are correct, and it does not
  test anything about the vendored set's coverage.
  ```bash
  make update-crds
  git checkout vendor/flux-crds vendor/cert-manager-crds
  git status --porcelain vendor/traefik-crds
  ```
  Run after C6's explicit CRD apply. **`make update-crds` re-vendors three groups** —
  `scripts/update-crds.sh`'s `CRD_GROUPS` is flux, cert-manager and traefik — so it rewrites three
  `VERSION` files and can surface unrelated live drift in the flux and cert-manager schemas. Those two
  groups are reverted above and are **out of scope for this exit**; leaving them in would let an
  unrelated flux schema change masquerade as evidence about Traefik, in either direction. Read only
  `vendor/traefik-crds/`.
  **PASS:** the only changed path is `vendor/traefik-crds/VERSION`, or the diff inside
  `vendor/traefik-crds/` is explained line by line.
  **FAIL:** a content diff in `vendor/traefik-crds/{middlewares.yaml,ingressroutetcps.yaml}` after
  C6 — then either C6's apply did not land, or the live schemas are neither the old ones nor 41.1.1's,
  and `crd-check` is validating against a schema the cluster does not enforce.
- **Rollback:** `git checkout vendor/traefik-crds`.
- **Gates:** `make check-ci` (crd-check is in it).

### T2 — the Flux HelmRelease, in `apply/20-infra/traefik/`

**Placement: `apply/20-infra/traefik/`, namespace `traefik-system`.** Traefik is infrastructure, and
`20-infra` is where cert-manager, the OVH webhook, Reflector, reloader, the CNPG operator and
kube-state-metrics already live; each has its own namespace, declared centrally in
`apply/00-bootstrap/namespaces.yaml`. It is not a new stage — no numbered directory, no
`stage-*.yaml`. `kube-system` is **not** an option: k3s's HelmChart already owns a Helm release named
`traefik` there, and two owners for one release name is a mess no later commit cleans up.
`traefik-system` also matches the sibling box, which is the fleet precedent this whole decision rests
on.

- **Files:**
  - `apply/20-infra/traefik/traefik.yaml` — new: `HelmRepository` + `HelmRelease`.
  - `apply/20-infra/kustomization.yaml` — **+1 line** (`- traefik/traefik.yaml`). Not optional:
    `kustomize-listing` exists precisely because `coder/coder-db.yaml` was committed, built green,
    reviewed green, and named by nothing.
  - `apply/00-bootstrap/namespaces.yaml` — **+1 `Namespace`** for `traefik-system`.
    `namespace-check` rejects a built object naming an undeclared namespace, so this is a gate
    requirement, not tidiness. It must also carry the pod-security decision every sibling documents,
    and here the answer is the same one `coder` and `monitoring` give:
    ```yaml
    pod-security.kubernetes.io/warn: restricted
    pod-security.kubernetes.io/warn-version: latest
    ```
    The 41.1.1 chart's default `containerSecurityContext` (`drop: [ALL]`, `runAsNonRoot`,
    `readOnlyRootFilesystem`, no privilege escalation) satisfies `restricted`, so this namespace gets a
    warning label with no warnings behind it — unlike `open-webui` and `files`, whose namespaces
    deliberately omit it with a comment saying why. Do not add the label without checking that claim
    against the rendered pod spec, and do not silently leave it off: an undocumented absence is what
    the siblings' comments exist to prevent.
  - **No top-level `namespace:` in any `kustomization.yaml`.** These trees span namespaces and that
    field rewrites them all; `namespace-check` greps for it and fails.
- **Copy:** n/a — stateless.
- **The values, phase A (install with no public address).** Rendered and re-rendered against the real
  41.1.1 chart with the same command shape `tools/chart-values-check.py` uses
  (`helm template traefik ./traefik -f values.yaml -n traefik-system`), and run through the actual
  gate against a scratch copy of this repo: `ok traefik 41.1.1`, 10 of 10 HelmReleases rendered, 0
  failures.

  ```yaml
  values:
    image:
      registry: docker.io
      repository: rancher/mirrored-library-traefik
      tag: "3.7.8"

    # Phase A: the old chart still owns the IngressClass. Claiming it here would fail the install
    # with AlreadyExists, and uninstalling the old chart first would leave every
    # ingressClassName: traefik Ingress unserved in the gap. C3 hands it over instead.
    ingressClass:
      enabled: false
      isDefaultClass: true
      name: traefik

    # STRICTER than today, not equivalent. The live kube-system/traefik Deployment carries
    # --api.dashboard=true and --ping=true, so the dashboard is ENABLED and merely unreachable
    # (:8080 is not in the Service and no IngressRoute exists). Say that in the PR; "matches current
    # behaviour" would be a false claim about this line. --ping=true is not a values key at all:
    # the chart hardcodes it, and the probes use it, so it stays either way.
    api:
      dashboard: false

    ports:
      websecure:
        http:
          tls:
            enabled: true   # already the chart default; set explicitly because today's Deployment
                              # really does carry --entryPoints.websecure.http.tls=true and this must
                              # not silently depend on a default surviving a chart bump.

    service:
      # No `helm.sh/resource-policy: keep` here, deliberately. On a LoadBalancer that annotation earns
      # its place by preserving an IP the cloud allocated for you. There is no allocated IP: the
      # externalIP is the node's own statically-configured address on eno1, and it survives whatever
      # happens to this object. What `keep` *would* do is worse than useless: a kept Service carrying
      # `externalIPs: [<TITAN_PUBLIC_IP>]` outlives the release that made it, so a later uninstall
      # leaves the public address DNAT-ing to endpoints that no longer exist. With
      # `externalTrafficPolicy: Local` and zero local endpoints kube-proxy has nowhere to send the
      # packet, so the host stops answering on 80/443 while `kubectl get svc` still shows the address
      # and nothing owns it any more — a black hole with no owner to delete it. Letting Helm delete the
      # Service on uninstall is the correct behaviour, and it is the default.
      spec:
        # service.spec is a verbatim passthrough (templates/_service.tpl renders toYaml .service.spec
        # plus the chart's own selector). The OLD top-level service.type is NOT read by 41.x: it is
        # ignored silently and the chart default (LoadBalancer) renders with no error. Everything
        # goes under spec.
        type: ClusterIP
        externalTrafficPolicy: Local
        ipFamilyPolicy: PreferDualStack   # k3s sets this in its valuesContent; kept for parity

    providers:
      kubernetesIngress:
        publishedService:
          # Phase A: with no externalIPs, publishing would copy this Service's ClusterIP into every
          # Ingress .status while the old Traefik is still the real path. Turn it on in C4, together
          # with externalIPs, so the status only ever moves to an address that actually answers.
          enabled: false

    priorityClassName: system-cluster-critical
    tolerations:
      - key: "CriticalAddonsOnly"
        operator: "Exists"
      - key: "node-role.kubernetes.io/control-plane"
        operator: "Exists"
        effect: "NoSchedule"

    accessLog:
      # Top-level `accessLog:` — NOT `logs.accessLog:`. That block is 40.x and 41.x rejects it at
      # render time (root-strict schema). Enabled because it is the only way to prove the client
      # source IP actually survives (C4 exit, §7), and because restoring the real peer address is
      # half the reason externalTrafficPolicy: Local was chosen.
      enabled: true
  ```

  Deliberately **not** set, with the reason:
  - `deployment.podAnnotations` `prometheus.io/*` — k3s sets these because Rancher bundles a
    Prometheus. titan runs none and casa scrapes by target over the mesh, so the annotation is inert
    here. Inert config is not parity, it is noise.
  - `providers.kubernetesCRD.allowCrossNamespace` / `crossProviderNamespaces` — P2c proves no
    reference crosses a namespace boundary.
  - `ports.web.http.redirections.entryPoint` — **today there is no HTTP→HTTPS redirect** and the
    chart does not add one by default. Adding one would be a behaviour change nobody asked for; the
    VPS has one and titan does not. If it is wanted, it is a separate PR. (Note the shape if it ever
    is: `ports.web.http.redirections.entryPoint.{to,scheme,permanent}` — 41.x rejects the old
    `ports.web.redirections` outright.)
  - `tlsStore` / `defaultCertificate` — not needed. Every Ingress carries `spec.tls` with a Secret in
    its own namespace, and today's install has no default certificate either, so SNI-less connections
    get Traefik's fake cert before and after. If a default cert is ever wanted it means adding
    `traefik-system` to the `secretTemplate` allow-list in
    `apply/40-certificates/titan-wildcard.yaml` — never copying the Secret by hand.

  The rest of the `HelmRelease` follows the repo's existing shape (`reflector.yaml`,
  `cert-manager.yaml`): pinned `version`, `interval: 30m`, `driftDetection.mode: enabled`, and
  `RetryOnFailure` at 5m for both install and upgrade. Two fields are called out because something else
  in this plan hard-codes them or departs from a sibling:
  - **`releaseName: traefik` is set explicitly**, not left to Flux's default. C3's IngressClass
    handover writes `meta.helm.sh/release-name: traefik` and `meta.helm.sh/release-namespace:
    traefik-system` onto the live object, and those strings must match what the release actually is or
    the adoption silently points at a release that does not exist. Flux's default *would* produce
    `traefik`, but a handover that hard-codes an annotation must not depend on a default it never
    names. The namespace half of that pair is `traefik-system` because the HelmRelease lives there —
    which is also why `kube-system` was ruled out above.
  - **`spec.install.crds: Create` and `spec.upgrade.crds: Create`** — *not* `CreateReplace`, which is
    what `cert-manager.yaml` uses. See T1: `CreateReplace` would replace all 25 live CRDs as a side
    effect of the C3 values upgrade, mid-cutover, on the objects every `Middleware` and
    `IngressRouteTCP` depends on. CRD refresh is C6's explicit `kubectl apply` instead.
  - **The retry shape is `strategy: {name: RetryOnFailure, retryInterval: 5m}` under both `install:`
    and `upgrade:`**, copied from `apply/20-infra/cert-manager/cert-manager.yaml:27-35`. It is spelled
    out because `crd-check` rejects anything else: `install.retry` / `upgrade.retries` are **not**
    declared in `vendor/flux-crds/helmreleases.yaml` (the only keys under `install` are `crds`,
    `strategy`, `remediation`, `timeout`, `replace`, `disable*`, `createNamespace`, `serverSideApply`),
    so an invented field builds fine, passes `kustomize-check`, and fails `crd-check` — which is the
    gate doing its job, but only after someone writes the wrong thing.

- **Blast radius of putting this in `apply/20-infra/` — said out loud because it is severe.**
  `apply/00-bootstrap/stage-infra.yaml` runs `wait: true` with `timeout: 10m0s`,
  `stage-certificates.yaml` has `dependsOn: infra`, and `stage-apps.yaml` has `dependsOn:
  certificates`. A Traefik `HelmRelease` that will not go Ready therefore does not merely stay red
  itself: it blocks certificate renewals, every app, the whole tesla stage, and the restic backups.
  The manifest's own comment already states this cost for cert-manager; Traefik inherits it exactly.
  C3's documented failure mode — an install refused with `AlreadyExists` during the IngressClass
  handover — is precisely a not-Ready release, so C3 carries an explicit escape hatch rather than
  letting `infra` sit red for ten minutes.

- **What the render proves** (measured, phase A): args come out as
  `--api.dashboard=false`, `--ping=true`, `--entryPoints.websecure.http.tls=true`,
  `--providers.kubernetescrd`, `--providers.kubernetesingress`, image
  `docker.io/rancher/mirrored-library-traefik:3.7.8`, Service `type: ClusterIP` with
  `externalTrafficPolicy: Local` and only ports `web:80`/`websecure:443` (the `traefik` :8080
  entrypoint is not exposed), ClusterRole `traefik-traefik-system`, and **no IngressClass object**.
  Phase B adds `kind: IngressClass` named `traefik` with
  `ingressclass.kubernetes.io/is-default-class: "true"`, `externalIPs: [<TITAN_PUBLIC_IP>]`, and
  `--providers.kubernetesingress.ingressendpoint.publishedservice=traefik-system/traefik`.
  **Note what the render does *not* contain: there is no
  `--providers.kubernetesingress.ingress-class` argument in either phase, and 41.1.1 never emits one —
  the string does not appear in `templates/_podtemplate.tpl` at all, and setting
  `providers.kubernetesIngress.ingressClass` in values changes nothing.** So the class filter is not
  an arg; Traefik resolves it from `IngressClass` objects whose `spec.controller` is
  `traefik.io/ingress-controller`. That is why C2's exit cannot be an args grep and must be a routing
  proof instead (see C2), and it is the same mechanism today's k3s install relies on — its
  `valuesContent` sets no ingress-class flag either.
- **Exit:** `make chart-values-check` reports `ok traefik 41.1.1`, and
  `make dry-run DRYRUN_CONTEXT=<admin context>` accepts the `HelmRelease`.
- **Rollback:** revert the PR. In phase A the new Traefik receives no traffic, so reverting is a
  plain `helm uninstall` by Flux and nothing user-visible moves.
- **Gates:** `make check-ci` **and** `make chart-values-check` **and** `make dry-run`.

### T3 — `nixos-configurations`: reverse D4, and say why

- **Files:** `nix/hosts/titan/vars.nix` (the `k3s.disable` list, currently `disable = [ ]` at
  ~line 77), and `nix/modules/nixos/public-host.nix` (the `ingressTCPPorts` description string).
- **Copy:** n/a.
- **The change:**
  ```nix
  # BEFORE
  # Keep the k3s bundle intact: Traefik + ServiceLB are the public ingress path
  # on a host with no LoadBalancer controller of its own (spec D4).
  disable = [ ];

  # AFTER
  # Reversed 2026-10-31: k8s-titan #209 runs a Flux-managed Traefik exposed as a
  # ClusterIP Service with externalIPs. D4 kept ServiceLB because there was no
  # LoadBalancer controller, and it turns out one was never needed: the public IP
  # is configured on eno1 with a /24 and an on-link gateway, so kube-proxy can
  # DNAT node:80/443 straight to the pod network. No klipper-lb, no svclb
  # DaemonSet, no NodePorts. See k8s-titan
  # docs/superpowers/specs/2026-10-31-titan-ingress-ownership-decision.md.
  disable = [ "traefik", "servicelb" ];
  ```
  **This PR must state plainly that it fully reverses `nix` spec D4** — a confirmed founding decision,
  `nix/docs/superpowers/specs/2026-10-01-ovh-single-node-k3s-design.md:52` and `:281` (in
  `nixos-configurations`, not this repo) — and give the reason the original reason no longer holds, in
  one sentence: *ServiceLB was kept because there was no LoadBalancer controller, and it turns out one
  was never needed.*
- **The firewall needs no change, and that is worth saying.** `nix/modules/nixos/public-host.nix:169-176`
  already defaults `ingressTCPPorts = [ 80 443 ]`, and nothing in `hosts/titan/` overrides it. So the
  NodePorts 31109/30431 that today's `LoadBalancer` Service allocated were **never publicly
  reachable** — default-deny already covered them — and retiring them shrinks nothing that was open.
  The only edit is the option's `description`, which still reads "Public ingress (Traefik via
  ServiceLB)" and is now false.
- **`servicelb` is a valid `--disable` token** even though ServiceLB is implemented by k3s's embedded
  cloud provider rather than a bundled manifest — accepted "for historical reasons". High confidence,
  documented.
- **Exit:** after apply and restart, `ps -o args= -C k3s | tr ' ' '\n' | grep disable` shows both
  tokens, and `kubectl -n kube-system get helmchart` is empty.
- **Rollback:** revert the PR and restart k3s. **This restores the bundled Traefik only if the old
  HelmCharts' resources were never uninstalled** — which is exactly what C1 guarantees and what §6
  phase-by-phase rollback depends on.
- **Gates:** `nix`'s own checks. **No gate in this repo covers this file** — say so in the PR, the way
  the migration plan says it for T2.

---

## 4. Wave 2 — the cutover runbook

**It is not atomic and it does not pretend to be.** The order is: orphan the CRDs → install the new
release with no public address → verify internally → hand over the IngressClass → move the address and
remove the old path. Each phase has its own rollback in §6.

### C0 — freeze and snapshot

- Announce the window. Take P2d's CR dump again immediately before C1 if anything changed.
- Confirm `kubectl -n kube-system get helmchart` shows both charts, and that P4 passed on a scratch
  cluster at the same k3s version.
- **Take the rollback record now, before anything is deleted.** §6's C4 and C5 rollbacks both restore
  from this file, and a record taken after the deletion cannot record what it deleted.
  ```bash
  kubectl -n kube-system get deploy traefik svc traefik -o yaml \
    > /tmp/kube-system-traefik-$(date +%F).yaml
  wc -c /tmp/kube-system-traefik-$(date +%F).yaml
  grep -c 'kind: Deployment\|kind: Service' /tmp/kube-system-traefik-$(date +%F).yaml
  cp /tmp/kube-system-traefik-$(date +%F).yaml <off-machine location>
  ```
  Strip the `status:` block and the `resourceVersion`/`uid`/`creationTimestamp` fields before re-
  applying; a captured `status` will be rejected or will confuse ServiceLB.
- **Exit:** both HelmCharts present; CR dump on disk; the record file is **non-empty** and
  `grep -c` prints **2** (one `kind: Deployment`, one `kind: Service`) — a file that does not contain
  both kinds is not a rollback record and C4 must not proceed without one; P1–P7 recorded on #209.

### C1 — orphan the CRDs (and the old workloads) deliberately

```bash
kubectl -n kube-system annotate helmchart traefik     helmcharts.helm.cattle.io/unmanaged=true --overwrite
kubectl -n kube-system annotate helmchart traefik-crd helmcharts.helm.cattle.io/unmanaged=true --overwrite
kubectl -n kube-system get helmchart -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.metadata.annotations}{"\n"}{end}'
```

- **This is a live, git-invisible change to objects this repo does not own.** It is not the
  HelmRelease drift AGENTS.md warns about — those are Flux's — but it is still out-of-band and must be
  written into the PR body and the runbook, because `make dry-run` cannot see it and `driftDetection`
  will never report it.
- **Exit — and it deliberately proves less than it looks like it should.** The only thing C1 changes is
  the presence of two annotations, so that is the only thing C1 can assert: **both HelmCharts carry
  `helmcharts.helm.cattle.io/unmanaged=true` in that output, and no `helm-install-*`/`helm-delete-*`
  Job appeared.** That is all. Annotating the HelmCharts does not delete anything, so "the 25 CRDs are
  still there" and "the Middleware still resolves" are **true before C1 runs and would be true if the
  annotation did nothing** — asserting them here is a tautology and must not be mistaken for evidence.
  **CRD survival is proven by P4 on a scratch cluster at the same k3s version, and re-proven live at
  C5**, where the flag actually lands and the check already sits. Do not record C1 as "CRD survival
  confirmed".
- **If the annotation is absent or a Job appears** — **stop** and use §6.C1's fallback. Do not continue
  into C2 on a cluster whose CRD survival rests on an annotation that did not take.

### C2 — land PR 1 and verify the new Traefik internally

PR 1 = T1's file list minus the vendor refresh, plus T2's phase-A values. Nothing user-visible moves.

```bash
kubectl -n traefik-system get pods,svc,deploy -o wide
kubectl -n traefik-system logs deploy/traefik | grep -iE 'error|watch|provider'
# liveness proof, from inside the cluster, with no external address involved:
kubectl -n traefik-system run probe --rm -it --restart=Never --image=curlimages/curl -- \
  -sS -o /dev/null -w '%{http_code}\n' http://traefik.traefik-system/
kubectl -n traefik-system exec deploy/traefik -- traefik version

# THE CHECK THAT ACTUALLY MATTERS IN PHASE A: is this Traefik watching the `traefik` class?
# A bare 404 from the Service proves only that the entrypoint answers. Route a REAL hostname
# through the new ClusterIP and compare it against what the old path returns for the same host.
SVC_IP=$(kubectl -n traefik-system get svc traefik -o jsonpath='{.spec.clusterIP}')
for h in grafana coder; do
  printf 'new %-10s %s\n' "$h" "$(kubectl -n traefik-system run probe --rm -i --restart=Never \
      --image=curlimages/curl -- curl -sk -o /dev/null -w '%{http_code}' \
      --resolve "$h.titan.arrieta.eu:443:$SVC_IP" "https://$h.titan.arrieta.eu/")"
  printf 'old %-10s %s\n' "$h" "$(curl -sk -m 10 -o /dev/null -w '%{http_code}' \
      "https://$h.titan.arrieta.eu/")"
done
# negative control, so a 404 means something: a host nobody serves must NOT match.
kubectl -n traefik-system run probe --rm -i --restart=Never --image=curlimages/curl -- \
  curl -sk -o /dev/null -w '%{http_code}\n' \
  --resolve definitely-not-served.titan.arrieta.eu:443:$SVC_IP \
  https://definitely-not-served.titan.arrieta.eu/
```

- **Exit:** pod `1/1 Running`, image `rancher/mirrored-library-traefik:3.7.8`; the Service is
  `ClusterIP` with **no** `externalIPs`; `traefik version` prints 3.7.8.
- **The class check, stated so it can fail.** For each host, **`new` must equal `old`** — the same code
  the live path returns, e.g. a 302 to authentik. **FAIL: `new` prints 404 while `old` prints anything
  else.** That is the shape of "Traefik built no router for this Ingress", and the single most likely
  cause is a class mismatch. **The negative control must print 404**; if it prints anything else the
  comparison above is meaningless, because the new Traefik is matching everything.
- **Why this is a routing proof and not an args grep.** It is tempting to assert
  `--providers.kubernetesingress.ingress-class=traefik` on the rendered Deployment, and it would be
  wrong: **41.1.1 never emits that argument** — the string appears nowhere in `templates/_podtemplate.tpl`, and
  setting `providers.kubernetesIngress.ingressClass` in values produces no flag (measured, T2). With
  `api.dashboard: false` there is no API to query either. So the only honest phase-A proof that the
  class filter is right is that a real hostname routes, and the only honest proof that the test means
  something is that a fake hostname does not.
- **Also confirm the old path is untouched:** `curl -sS -o /dev/null -w '%{http_code}\n'
  https://coder.titan.arrieta.eu/` from off-node still answers as before, and
  `kubectl -n kube-system get deploy traefik -o jsonpath='{.spec.replicas}'` is unchanged.
- **Gates:** `make check-ci`, `make chart-values-check`, `make dry-run`.

### C3 — hand over the IngressClass, with no gap

Two Helm releases cannot both own `IngressClass/traefik`, and Helm refuses to install over an object it
does not own. The fix is Helm's own adoption rule, read from `pkg/action/validate.go` (v4.3.0):
`existingResourceConflict()` calls `checkOwnership()`, which accepts an existing object iff it carries

- label `app.kubernetes.io/managed-by: Helm`
- annotation `meta.helm.sh/release-name: <new release name>`
- annotation `meta.helm.sh/release-namespace: <new release namespace>`

and helm v4's `verifyOwnershipBeforeDelete` then makes the **old** release skip that object when it is
uninstalled. So the handover is safe in both directions, and there is no window in which the
IngressClass is missing.

```bash
# 0. escape hatch first. `stage-infra.yaml` runs wait:true / timeout:10m0s and every later stage
#    dependsOn it, so a refused adoption here would hold certificates, apps, tesla and backups red
#    for ten minutes (T2, blast radius). Suspending the release costs nothing and makes the failure
#    reversible by flipping one field back. It also freezes the window in which the ownership
#    annotations and the phase-B values disagree, which is exactly the window described below.
flux -n traefik-system suspend hr traefik --interactive=false

# 1. re-point ownership BEFORE the new release claims the name (object is untouched otherwise)
kubectl annotate ingressclass traefik \
  meta.helm.sh/release-name=traefik \
  meta.helm.sh/release-namespace=traefik-system --overwrite
kubectl label ingressclass traefik app.kubernetes.io/managed-by=Helm --overwrite
kubectl get ingressclass traefik -o jsonpath='{.metadata.labels}{"\n"}{.metadata.annotations}{"\n"}'
```

Then **PR 2** flips, in one commit: `ingressClass.enabled: true` (name already `traefik`),
`providers.kubernetesIngress.publishedService.enabled: true`, and
`service.spec.externalIPs: ["<TITAN_PUBLIC_IP>"]`. Force the sync
(`flux reconcile kustomization infra --with-source`; `requestedAt` only fires when the value
changes — `docs/flux-manual-sync.md`).

- **Exit:** `kubectl get ingressclass traefik -o yaml` shows the new ownership annotations and
  `helm.sh/chart: traefik-41.1.1`; `kubectl get ingress -A` still lists every host; the old Traefik
  keeps serving throughout.
- **Then resume, and only then:** `flux -n traefik-system resume hr traefik --interactive=false`. The
  release was suspended while the sync landed, so it has not acted on PR 2 yet — resuming is what lets
  the adoption attempt happen. Watch `flux -n traefik-system get hr traefik` immediately. If the
  adoption is refused, **re-suspend at once** (`flux -n traefik-system suspend hr traefik
  --interactive=false`) and revert; the release then sits paused and inert instead of retrying, and
  `stage-infra` is not held red for the full 10-minute timeout while you decide. The suspend is a
  brake, not a substitute for the adoption succeeding — C3 is not done until `flux get hr traefik`
  reports the release Ready with the new generation.
- **Fallback if adoption is refused** (P3c said helm 3.x, or the install errors "exists and cannot be
  imported"): accept a **bounded** gap instead of an unbounded one — delete `ingressclass traefik`
  immediately after the phase-B commit is applied and sync immediately, so the class is absent for
  seconds rather than minutes. State the gap in the PR. Do not leave two releases fighting over one
  object.
- **Gates:** `make chart-values-check`, `make dry-run`.

### C4 — move the address and remove the old path. **This is the outage.**

The two paths cannot be trusted side by side on one node address: `svclb-traefik-*` holds
`hostPort` 80/443, which the CNI implements as node-level DNAT, and kube-proxy's externalIPs rules
DNAT the same `node:80`/`node:443` in `nat PREROUTING`. Overlapping them is an ambiguity, not a
graceful handover. So the swap is deliberate and short.

**Outage window:** from the moment the old path is torn down (step 1) until kube-proxy programs the
externalIPs rules (step 2, already applied and synced). **Plan for under 60 seconds.** Pre-stage the
phase-B commit before starting so step 2 is a sync, not an edit.

**Affected hostnames: all of them — derive the list, do not type it.** §1 already requires that any
count of affected hostnames come from the cluster, and a tree-derived list is exactly the blind spot
that hid `auth` and `sure` here once. Run this and paste its output into the PR:

```bash
kubectl get ingress -A -o jsonpath='{range .items[*]}{.spec.rules[*].host}{"\n"}{end}' | sort -u
kubectl get ingress -A --no-headers | wc -l      # 15
```

Every public hostname titan serves goes through this path; there is no subset that is unaffected. Expect
**15 Ingress objects on 14 hostnames**, of which `auth` (authentik itself) and `sure` are
chart-rendered and therefore invisible to a tree-derived count — and `auth` is the forwardAuth target,
so a broken `auth` makes every gated login fail while the gates themselves still look fine. Add
`telemetry.titan.arrieta.eu` on top: it is an `IngressRouteTCP`, not an Ingress, so the command above
cannot see it.

```bash
# 0. phase-B values already applied and synced (C3's PR). Confirm before tearing anything down:
kubectl -n traefik-system get svc traefik -o jsonpath='{.spec.type} {.spec.externalIPs} {.spec.externalTrafficPolicy}{"\n"}'

# 1. OUTAGE STARTS. Remove the old path. The svclb DaemonSet is NOT garbage-collected once the
#    ServiceLB controller is gone, so it is deleted by hand:
kubectl -n kube-system get ds,pod | grep svclb-
kubectl -n kube-system delete ds -l 'app.kubernetes.io/name=servicelb'   # or by name: svclb-traefik-da79b8e7
kubectl -n kube-system delete svc traefik
kubectl -n kube-system delete deploy traefik
# If the LoadBalancer Service hangs on its ServiceLB finalizer, remove the finalizer explicitly and
# say so in the PR — a stuck Terminating Service is a real outcome here, not a curiosity.

# 2. OUTAGE ENDS as kube-proxy resyncs. Prove the host ports are free:
sudo ss -lntp | grep -E ':80 |:443 ' || echo "nothing listening on 80/443 — correct"
```

**Read `ss -lntp` correctly, or it will mislead you.** Before the cutover it shows klipper-lb
listening on `:80`/`:443`. After it, the correct result is **no listener at all** — kube-proxy DNATs,
it does not listen. An empty result is the pass condition, and "but nothing is listening!" is the
mistake this line exists to prevent.

Then retire the old `traefik` release record — **only `traefik`, and only after §7 is fully green**.
**`helm -n kube-system uninstall` needs an admin context**: Helm stores release records as Secrets and
`k8s-reader` is Forbidden on them.

```bash
helm -n kube-system list --all
# only after §7 is fully green, and only this one release:
helm -n kube-system uninstall traefik

# THE CHECK THAT MAKES THAT COMMAND SAFE TO HAVE RUN — run it, do not skip it:
kubectl get ingressclass traefik -o jsonpath='{.metadata.annotations}{"\n"}'
helm -n kube-system list --all
```

- **Exit:** the IngressClass still exists and its annotations still read
  `meta.helm.sh/release-namespace: traefik-system`, and `helm -n kube-system list --all` shows only
  `traefik-crd` left from the old pair.
- **FAIL:** `kubectl get ingressclass traefik` returns NotFound, or the annotations point back at
  `kube-system`. **This is a live, plausible outcome, not a formality:** `verifyOwnershipBeforeDelete`
  — the helm-v4 behaviour that makes the old release *skip* an object it no longer owns — is exactly
  what P3c leaves open. Under helm 3 the uninstall deletes everything in the stored manifest
  regardless of the live `meta.helm.sh/*` annotations, which would delete `IngressClass/traefik`
  **after all of §7 had gone green** and black-hole all 15 hostnames with a perfectly healthy Traefik
  pod. If it fails: re-apply the class from the phase-B chart output and
  `flux -n traefik-system reconcile hr traefik --with-source` (see §6).
- **If P3c came back UNKNOWN, do not run this step at all yet.** Re-run C3's adoption check first, on
  the scratch cluster if necessary, and confirm the installed helm is v4.x. Until then leave the
  `traefik` release record in place; an orphaned record costs nothing, a deleted IngressClass costs
  everything.

  **Ordering, so this is not circular:** §7.2 runs between the teardown in step 1 and this command. The
  sequence is teardown → §7.2 green → `helm uninstall traefik` → the two checks above → C5.

> **Permanent warning — this does not expire.** The `traefik-crd` release record **survives in
> `kube-system` forever, on purpose.** It is the release that owns the 25 Traefik CRDs, and
> `helm -n kube-system uninstall traefik-crd` deletes all 25, which **cascade-deletes every
> `Middleware` and the `IngressRouteTCP`** in the tree — the forwardAuth gates and the Tesla telemetry
> intake — while `crd-check` and `ingress-auth` stay green because they read vendored schemas, not the
> cluster. **Never run it.** Deleting that record is not cleanup; it *is* the cascade. It is kept rather
> than removed because uninstalling it is exactly the failure this plan exists to avoid, and because
> after C5 the HelmChart that could fire it automatically is gone — leaving only this warning and
> operator discipline as the guard. `helm -n kube-system list --all` in §7.2 is what keeps the
> surviving record visible instead of forgotten.

- **Gates:** none (live).

### C5 — land PR 3 (`nixos-configurations`) and close the loop

Order matters: **C1 must precede this**, because the flag is what deletes the HelmCharts and
`unmanaged` is the only thing standing between that deletion and a cascade. Between C1 and C5 the
bundled Traefik is an unmanaged orphan, which is exactly the state the transition wants.

Expect a k3s restart when the flags change. The control plane blips; the data plane and the new
Traefik pod keep serving.

- **Exit:** `ps -o args= -C k3s | tr ' ' '\n' | grep disable` shows `traefik` and `servicelb`;
  `kubectl -n kube-system get helmchart` is empty; the 25 CRDs and the 3 Middlewares still exist;
  `kubectl -n kube-system get ds,pod | grep svclb-` is empty.
- **Gates:** `nix`'s own.

### C6 — post-cutover hygiene

- Re-vendor the Traefik CRDs (T1) and commit the diff, or commit the explanation of why the diff is
  empty.
- Record the cutover in a `docs/` runbook: the new chart pin, the new namespace, the fact that
  `api.dashboard` is now genuinely off, and the `Local` footgun (a second node, or an unschedulable
  Traefik pod, silently drops all traffic instead of load-balancing).
- Update `AGENTS.md`: the ingress story is no longer "k3s' bundled Traefik, configuration not managed
  here". That sentence is what this whole plan falsifies, and leaving it is how the next person
  re-derives all of this.
- **Deferred, its own PR, after the cutover is proven stable:** chart 41.1.1 → 42.2.0 and Traefik
  3.7.8 → 3.7.16 (option C). Two values keys, its own rollback, and re-read the F20 note first — a
  future chart may ship Gateway API CRDs again.

---

## 5. Which PR lands first, and why

| order | repo | PR | why here |
|---|---|---|---|
| **1** | `titan` | `apply/20-infra/traefik/` + namespace + kustomization line, **phase-A values**, plus a note in the PR saying why `vendor/traefik-crds/` is deliberately untouched (T1) | It is the only change that can land with zero user-visible effect, and every later step is a rollback away only if it is already in place and proven. Landing anything else first means the first risky step happens before the new path exists. |
| — | live | **C1** — annotate both HelmCharts `unmanaged` | Must precede the flag that deletes the HelmCharts. This is the CRD-survival precondition and it is not negotiable. |
| **2** | `titan` | phase B: `ingressClass.enabled: true`, `publishedService.enabled: true`, `service.spec.externalIPs` — preceded by the IngressClass ownership patch | The address move and the old-path teardown are one window; the IngressClass handover is gap-free only if it happens while the old release is still installed but no longer owns the object. This PR is landed and synced as **C3**, and the address actually moves in **C4**. |
| — | live | **C4** — the outage: `externalIPs` go live, the old Deployment/Service are removed by hand | Everything user-visible happens here, once. |
| **3** | `nix` | `disable = [ "traefik", "servicelb" ]` + comment + `ingressTCPPorts` description | **Deliberately after C4, not before.** See the note below. |
| 4 | `titan` | CRD re-vendor + `AGENTS.md` + runbook | Documentation of a state that must exist before it can be described. |

**Why the `nix` flag lands after the outage, not before.** C4's rollback is "remove `externalIPs`,
re-create the old `Service type: LoadBalancer` in `kube-system`, let ServiceLB re-provision its
DaemonSet". That rollback **only exists while ServiceLB is still enabled**, i.e. while `servicelb` is
still a live k3s component. Land PR 3 first and the moment C4 goes wrong the fallback path is gone: the
re-created LoadBalancer Service would sit unprovisioned forever, with no `svclb-` DaemonSet to bind the
public address. So the order is *prove the new path answers from off-node, then remove the old one
permanently*. §4, §5 and §6 all encode this and must not be re-sorted independently.

**Do not squash these together.** The failure mode this ordering buys against is a single commit that
both deletes the CRDs and moves the address, where the outage and the cascade are indistinguishable
and the only rollback is "undo everything".

---

## 6. Rollback, per phase

| phase | what to undo | how | what it costs |
|---|---|---|---|
| **C1** | the `unmanaged` annotations | `kubectl -n kube-system annotate helmchart <c> helmcharts.helm.cattle.io/unmanaged-` | Nothing, **as long as the flag has not landed**. Once `--disable=traefik` is live the HelmCharts are gone and the annotation is moot — but say precisely what that costs: the CRDs survive from C5 onwards because the release records went with them, **not** because anything is still guarding them. The `traefik-crd` release record is deliberately kept (§1.1), so from C1 the only thing standing between a stray `helm uninstall` and a 25-CRD cascade is the warning in §1.1 and the discipline in C4. |
| **C1 fallback** | if `unmanaged` did **not** suppress the uninstall | Let the cascade happen, then restore: `kubectl apply` the 25 CRDs from 41.1.1's `crds/` (already on disk from P5's `helm pull`), wait for establishment, then `kubectl apply -f /tmp/traefik-cr-dump-*.yaml` to restore the Middlewares and the IngressRouteTCP. | A real outage **and** a window in which the forwardAuth middlewares do not exist. Traefik disables a router whose middleware is missing, so gated hosts answer 404 rather than serving open — bad, not catastrophic. Schedule it as a full outage, not a swap. **If P4 failed, do this on the scratch cluster first.** |
| **C2** | the new release | revert PR 1; Flux uninstalls it | Nothing user-visible. The old path never stopped. |
| **C3** | the IngressClass handover | re-point the two `meta.helm.sh/*` annotations back to `traefik`/`kube-system`, set `ingressClass.enabled: false`, sync | Brief confusion; the object is never absent, so no Ingress goes unserved. |
| **C4** | the address move | remove `externalIPs` from the values and sync; re-create the old `Service type: LoadBalancer` in `kube-system` from the **C0 record** (`/tmp/kube-system-traefik-<date>.yaml`) so ServiceLB re-provisions its DaemonSet | A second outage of similar length. **Two hard preconditions.** This rollback exists only **while `servicelb` is still enabled**, i.e. before PR 3 lands — which is why §5 puts PR 3 after C4 and not before. And re-creating the Service needs an **admin context**, as does C4's `helm uninstall`, because Helm release records are Secrets and `k8s-reader` cannot read them. |
| **C5** | the flags | revert PR 3, restart k3s | Restores the bundled Traefik **only if** its resources were never uninstalled. After C4 deleted the old Deployment/Service by hand, rollback means re-applying them from the **C0 record**, not just flipping the flag. That record was taken in C0 precisely so that it exists before the deletion it is for. |
| **C4 — old release uninstall** | `helm -n kube-system uninstall traefik` deleted `IngressClass/traefik` (the helm-3 case P3c cannot rule out) | Re-create the class from the phase-B chart output (`helm template` of the pinned 41.1.1 with `ingressClass.enabled: true`, or `kubectl apply` the single rendered `IngressClass` document), then `flux -n traefik-system reconcile hr traefik --with-source` and confirm the ownership annotations landed. | A second full outage of the same length, on every hostname, with a healthy Traefik pod the whole time — which is what makes it confusing rather than merely bad. This is why C4 gates the uninstall on §7 and on P3c. |
| **any** | everything | `git revert` each PR in reverse order | Only works phase-by-phase. There is no single revert that undoes a live cutover. |

---

## 7. Gates and post-cutover verification

### 7.1 Repo gates

`make check` where the age key and network are available; otherwise `make check-ci`, **and the PR
records which ran**. **`make check` cannot run in this workspace** — `validate`, `db-url-check`,
`oidc-check` and the other blueprint gates need the sops age private key, which must never sit in CI
or in a scratch checkout. Baseline taken here: `make check-ci` → **all keyless gates passed**
(40 objects against 9 vendored CRDs, 232 objects across 18 namespaces, 109 manifests / 10
kustomizations / 0 unlisted).

`chart-values-check` is in `check` but **not** `check-ci` — it needs network to pull charts, and
`check-ci`'s contract is the tree alone. It has its own CI job. It was run here directly against a
scratch copy of this repo with the T2 manifest added:

```
ok   traefik   41.1.1   via https://traefik.github.io/charts
chart-values-check: 10 of 10 HelmRelease(s) rendered, 0 skipped, 0 failure(s)
```

and `make check-ci` was re-run on that same scratch copy with the new file, the namespace and the
kustomization line in place: **all keyless gates passed** — 41 objects against 9 vendored CRDs, 234
objects across 19 namespaces, 10 HelmReleases rendered, 109 manifests / 10 kustomizations / 0 unlisted.

That re-run is also what caught the retry-field mistake recorded in T2: an invented `install.retry`
builds and fails `crd-check`, so copy `cert-manager.yaml`'s `strategy:` block rather than inventing a
field name.

| gate | why it bites here |
|---|---|
| `chart-values-check` | the root-strict `values.schema.json` is the only thing that catches a 40.x-shaped key on a 41.x chart. **This is the gate for T2.** |
| `kustomize-listing` | `apply/20-infra/traefik/traefik.yaml` must be named by `apply/20-infra/kustomization.yaml` or Flux never applies it. |
| `namespace-check` | `traefik-system` must be declared in `00-bootstrap/namespaces.yaml`; also re-greps for a top-level `namespace:`. |
| `crd-check` | reads `vendor/traefik-crds/`, **not the cluster** — which is exactly why a live CRD cascade would leave it green. Green here does not mean safe. |
| `ingress-auth` | the three `Middleware` objects and their references must still resolve. Same caveat as `crd-check`: it reads vendored schemas. |
| `release-secrets` / `secret-refs` | the new `HelmRelease` references no Secret, so both should report it unchanged. |
| `dry-run` | **not in `check` at all.** Needs an admin context; `k8s-reader` is Forbidden for it. The only gate that asks the live API server. |

### 7.2 Live verification after C4 — run all of it, from off-node where it says so

```bash
# 1. the release itself
kubectl -n traefik-system get pods,svc,deploy -o wide
kubectl -n traefik-system describe svc traefik | grep -E 'Type|External|Traffic Policy|Port'

# 2. the CRDs survived, and the CRs still resolve
kubectl get crd --no-headers | grep -cE 'traefik\.io|hub\.traefik\.io'      # 25
kubectl get middleware -A
kubectl -n apps get ingressroutetcps tesla-telemetry -o yaml
# the old release records. Both are still present at this point: C4's `helm uninstall traefik` runs
# only after §7.2 is green. Admin context required — helm reads release records, which are Secrets.
helm -n kube-system list --all        # expect two rows: traefik, traefik-crd — one after C4's uninstall

# 3. the IngressClass is real and owned by the new release
kubectl get ingressclass traefik -o yaml

# 4. the old path is gone, by hand and completely
kubectl -n kube-system get ds,pod | grep svclb- || echo "no svclb — correct"
sudo ss -lntp | grep -E ':80 |:443 ' || echo "nothing listening on 80/443 — correct (kube-proxy DNATs, it does not listen)"

# 5. THE ONE THAT MATTERS: from a machine that is neither titan nor a pod on titan.
# Derive the host list from the cluster; do NOT type it. A hand-typed list is how `auth` and `sure`
# went missing from this loop once, and `auth` is the forwardAuth target.
dig +short coder.titan.arrieta.eu                       # must be <TITAN_PUBLIC_IP>
kubectl get ingress -A -o jsonpath='{range .items[*]}{.spec.rules[*].host}{"\n"}{end}' \
  | sort -u > /tmp/titan-hosts.txt
wc -l /tmp/titan-hosts.txt                              # expect 14
while read -r h; do
  printf '%-34s %s\n' "$h" "$(curl -sS -m 10 -o /dev/null -w '%{http_code}' "https://$h/" 2>&1)"
done < /tmp/titan-hosts.txt
# The two chart-rendered hosts must appear in that output. If they do not, the loop proved nothing:
grep -E '^(https://)?(auth|sure)\.' /tmp/titan-hosts.txt || echo "FAIL: auth/sure missing from the derived list"
nc -tz telemetry.titan.arrieta.eu 443 && echo "telemetry passthrough up"   # IngressRouteTCP, not an Ingress

# 6. the gates are still gates, not decoration
curl -si https://llm.titan.arrieta.eu/       | head -1   # 401 from the bearer-auth frontend
curl -si https://grafana.titan.arrieta.eu/   | head -3   # 302 to authentik
curl -si https://tesla.titan.arrieta.eu/     | head -3   # 302 to authentik
curl -si https://investing-agent.titan.arrieta.eu/ | head -3   # 302
# and the identity those three redirect TO must itself answer, or every gated login is dead while all
# three checks above still pass. This is the check the tree-derived host list could not produce.
curl -sS -o /dev/null -w 'auth -> %{http_code}\n' https://auth.titan.arrieta.eu/

# 7. client source IP actually preserved (P6). Off-node host; read the peer field Traefik logs.
kubectl -n traefik-system logs deploy/traefik --tail=20
# PASS: the off-node host's public egress address appears as the client.
# FAIL: a 10.x / 169.254.x / cni-range address — that is the masquerade Local was supposed to remove.
# A curl from titan itself ALWAYS shows a masqueraded address by design; do not use it as evidence.

# 8. the dashboard really is closed now (it was unreachable-but-enabled before; now it is off)
kubectl -n traefik-system exec deploy/traefik -- sh -c \
  'wget -qO- http://127.0.0.1:8080/dashboard/ 2>&1 | head -3 || echo "no dashboard — as intended"'

# 9. Ingress status now points at the address that answers
kubectl get ingress -A -o custom-columns=NS:.metadata.namespace,NAME:.metadata.name,\
ADDR:.status.loadBalancer.ingress[0].ip
```

- **Exit:** the derived host file holds **14** names and contains `auth.` and `sure.`; every hostname
  in it answers with the same code it returned before the cutover; `auth` itself answers, so the
  forwardAuth target is live and not merely referenced; the three forwardAuth hosts still redirect and
  `llm` still 401s; the client IP check passes from off-node; nothing listens on 80/443; 25 CRDs and 3
  Middlewares present; `helm -n kube-system list --all` shows the old pair (`traefik`, `traefik-crd`)
  and nothing else — and after C4's uninstall, exactly the one surviving `traefik-crd` row.
- **Rollback:** §6 C4.
- **Gates:** none (live).

---

## 8. Open questions — what could not be settled from this repo

These are the honest gaps. None of them blocks writing this plan; **P1–P4 must be answered before C1
runs**, and the rest before C4.

1. **Does `helmcharts.helm.cattle.io/unmanaged` suppress the uninstall Job on the helm-controller
   build shipped in `v1.35.8+k3s1`?** Source on `master` says yes — `shouldManage()` gates the scoped
   `OnRemove` handler as well as `OnChange` — but that is a reading of `master`, and the pre-flight
   rated it medium confidence for good reason. **P4 is the answer.** If P4 fails, §6's C1 fallback is
   a full outage, not a swap, and this plan must be re-sequenced rather than improvised around.
2. **Do the live traefik CRDs carry `helm.sh/resource-policy: keep`?** P1. Expected answer: no. Note
   that "no" cannot be fixed by annotating them — helm reads that annotation from the stored release
   manifest, never from the live object.
3. ~~**What is the 14th Ingress?**~~ **Resolved 2026-10-31: there are 15 live Ingress objects on 14
   hostnames, and the tree builds only 13.** The two the tree misses are `auth/authentik-server` and
   `sure/sure`, both chart-rendered by their `HelmRelease`. Not drift — a blind spot in tree-derived
   counting. See §1.
4. **Which helm does `rancher/klipper-helm` ship on this k3s build?** P3c, asked of the image rather
   than the tag. It decides whether `verifyOwnershipBeforeDelete` exists, and therefore whether the C3
   IngressClass handover is provably safe in both directions or needs the bounded-gap fallback — **and
   whether C4's `helm -n kube-system uninstall traefik` is safe to run at all**, since under helm 3 that
   command can delete `IngressClass/traefik` after §7 has gone green. If P3c returns UNKNOWN, C4's
   uninstall is blocked until it is answered.
5. **Does titan have Gateway API CRDs at all, and who owns them?** 41.1.1 ships none in `crds/`, so
   this plan neither creates nor touches them — but if the k3s `traefik-crd` chart installed them and
   they are cascade-deleted with the rest, something downstream could notice. One command:
   `kubectl get crd -o name | grep gateway.networking.k8s.io`.
6. **Does titan's NixOS firewall affect pod-forwarded traffic at all?** The research found one NixOS
   user report that kube-proxy's iptables rules bypass the module-managed firewall entirely. Treated
   as non-authoritative and proven from off-node instead (§7.2 step 5). If step 5 fails with a healthy
   pod, this is the first suspect.
7. **Is `accessLog.enabled: true` wanted permanently, or only for the client-IP proof?** It is in the
   values because restoring the real peer address is half the reason `Local` was chosen, and because
   promtail ships these logs to casa's Loki. If the log volume is unwanted, drop the key after §7.2
   step 7 passes — but then the client-IP guarantee becomes unprovable in production, which is a worse
   trade than the volume.
8. **Does anything read Ingress `.status`?** Nothing in this tree does (DNS lives in OVH/`tf`, no
   external-dns), which is why phase A can leave `publishedService` off without consequence. If an
   external consumer exists, the phase-A/phase-B split needs revisiting.
9. ~~**`F19` is a dangling citation.**~~ **Resolved 2026-10-31 in commit `39a5f01`.** The migration
   spec's D5 and the ingress-ownership decision doc now state the version distance in plain terms
   instead of citing an undefined finding id, so there is nothing left to repair and no meaning for
   this plan to invent. Recorded here only so the history is visible.
10. **`review/209-preflight-findings.md` and `review/209-plan-review.md` are untracked** in this
    workspace (`git status` shows `?? review/`). This plan cites them heavily. **Assignment: both files
    land in PR 4** (the titan CRD re-vendor + `AGENTS.md` + runbook PR), under `docs/` — the durable
    parts of the pre-flight findings belong in the cutover runbook, and the review belongs beside it —
    and every `review/…` citation in this plan is rewritten to the committed path in the same PR. They
    must not be cited from PR 1–PR 3 as though they existed on `main`, because they do not. If PR 4 is
    ever landed before this plan is executed, the citations in PR 1's PR body should quote the relevant
    finding inline instead of pointing at a path.
11. **The ServiceLB finalizer string is not known from this repo.** C4 deletes the old `Service type:
    LoadBalancer`, and if k3s's embedded cloud provider does not clear the finalizer the Service sits
    `Terminating` forever and the outage does not end. The plan says "remove the finalizer explicitly"
    but cannot name the string, because it is set by k3s' cloud controller, not by anything in this
    tree. **P2a must capture it** — `kubectl -n kube-system get svc traefik -o jsonpath='{.metadata.finalizers}'`
    — and the exact value belongs in the C4 PR body, so the operator is not guessing it live under an
    outage clock. Treat it as an owned open item, not a detail.

### 8.1 Constraints honoured, restated so a reviewer can check them in one pass

- No concrete public IPv4 anywhere in this file or in any manifest it specifies — `<TITAN_PUBLIC_IP>`
  throughout. (The VPS manifest that inspired the values block contains a real address; it was
  deliberately **not** copied.)
- No top-level `namespace:` in any `kustomization.yaml`; `namespace-check` greps for it.
- Every new manifest is listed in its `kustomization.yaml` — `apply/20-infra/kustomization.yaml`
  gains exactly one line, and `kustomize-listing` proves it.
- `Middleware` CRs stay in the app's own namespace and keep being referenced as
  `<ns>-<name>@kubernetescrd`. Nothing in this plan moves one.
- **No attribution trailers in commit messages.** No `Co-Authored-By:`, no model or vendor named as a
  contributor. If provenance is needed, use the session id.
