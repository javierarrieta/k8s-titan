# Research: k3s ingress ownership cutover — five blocking unknowns

Cluster: single-node k3s `v1.35.8+k3s1` on NixOS. Plan: disable bundled `traefik` +
`servicelb` in nixos-configurations; run a Flux-managed Traefik `HelmRelease`
(ClusterIP + `externalIPs`).

## Summary

`--disable=traefik` disables the **manifest file** `traefik.yaml`, and at `v1.35.8+k3s1` that one
file declares **both** the `traefik` and the `traefik-crd` `HelmChart`. Disabling it uninstalls
both releases, and because `traefik-crd` installs its CRDs as ordinary release templates,
`helm uninstall` deletes the CRDs — cascade-deleting every `Middleware`, `IngressRoute` and
`IngressRouteTCP` in the cluster. That must be orphaned deliberately before the flag is flipped.
The other four questions are mechanically solvable: `servicelb` is a valid token but leaves
orphaned `svclb-*` DaemonSets holding hostPort 80/443; kube-proxy is hardcoded to `iptables`
mode; `externalTrafficPolicy: Local` is the right choice and on one node only affects client-IP
preservation; and the upstream chart supports everything needed under `service.spec`, with a
root-strict `values.schema.json` that rejects a typo'd key at render time.

## Findings

### Q1 — Does `--disable=traefik` also disable `traefik-crd`? Does anything get uninstalled?

1. **Claim:** k3s resolves `--disable=<name>` against the **basename of the bundled manifest
   file**, not a HelmChart name. `--disable=traefik` disables `server/manifests/traefik.yaml` as
   a unit.
   **Sources:** [k3s `pkg/deploy/controller.go`](https://github.com/k3s-io/k3s/blob/master/pkg/deploy/controller.go),
   [k3s docs, configuration](https://docs.k3s.io/installation/configuration).
   **Support:** direct. **Confidence:** high.
2. **Claim:** at exactly `v1.35.8+k3s1`, `manifests/traefik.yaml` contains **two** HelmCharts in
   one file — `traefik-crd` (`traefik-crd-40.1.4+up40.1.0.tgz`) and `traefik`
   (`traefik-40.1.4+up40.1.0.tgz`, image `rancher/mirrored-library-traefik:3.7.8`). There is no
   separate `traefik-crd.yaml`, so there is no way to disable one without the other.
   **Sources:** [raw manifests/traefik.yaml @ v1.35.8+k3s1](https://raw.githubusercontent.com/k3s-io/k3s/v1.35.8%2Bk3s1/manifests/traefik.yaml).
   **Support:** direct (tagged file fetched). **Confidence:** high.
3. **Claim:** disabling an AddOn is an active uninstall: "Disabled AddOns are actively uninstalled
   from the cluster, and the source files deleted from the manifests directory."
   **Sources:** [k3s docs](https://docs.k3s.io/installation/configuration).
   **Support:** direct (quoted). **Confidence:** high.
4. **Claim:** deleting a `HelmChart` makes helm-controller run `helm uninstall`. Its `OnRemove`
   creates a delete Job and logs `Uninstalled HelmChart using Job %s/%s, removing resources`. A
   finalizer holds the object until that Job finishes, and **removing the finalizer does not
   prevent the uninstall** — the controller re-adds it and runs the delete Job anyway.
   **Sources:** [helm-controller `chart.go`](https://github.com/k3s-io/helm-controller/blob/master/pkg/controllers/chart/chart.go),
   [helm-controller#127](https://github.com/k3s-io/helm-controller/issues/127),
   [field report](https://blog.romandanko.sk/posts/k3s-helm-controller-silent-uninstalls/).
   **Support:** direct + corroborating field report. **Confidence:** high.
5. **Claim:** CRDs installed from a chart's `templates/` are ordinary release resources and are
   deleted by `helm uninstall` unless annotated `helm.sh/resource-policy: keep`. CRDs installed
   from a chart's `crds/` directory are installed once and **never** upgraded or deleted by Helm.
   **Sources:** [helm uninstall](https://helm.sh/docs/helm/helm_uninstall/),
   [helm tips (`resource-policy: keep`)](https://helm.sh/docs/howto/charts_tips_and_tricks/),
   [helm CRD best practices](https://helm.sh/docs/chart_best_practices/custom_resource_definitions/),
   [HIP-0011](https://helm.sh/community/hips/hip-0011/).
   **Support:** direct for helm semantics. **Researcher inference:** that k3s's `traefik-crd` chart
   puts its 25 CRDs in `templates/` without the keep annotation — I read the chart tree but did
   not grep every file for the annotation. **Confidence:** medium on the annotation's absence,
   high on the consequence if absent.
   **Verify live:** `kubectl get crd middlewares.traefik.io -o jsonpath='{.metadata.annotations}{"\n"}{.metadata.ownerReferences}{"\n"}'`.
6. **Claim:** the supported escape hatch is `helmcharts.helm.cattle.io/unmanaged: "true"` on the
   `HelmChart` (added in helm-controller #137 / k3s#5263), which makes helm-controller stop
   managing the chart.
   **Sources:** [k3s#5263](https://github.com/k3s-io/k3s/pull/5263),
   [k3s#5287 test plan](https://github.com/k3s-io/k3s/issues/5287).
   **Support:** direct that the annotation exists. **Confidence:** high it exists; **medium** that
   it fully suppresses the delete Job on this version — upstream documents it as "the chart is not
   updated", not explicitly "not uninstalled". Test on scratch before relying on it.
7. **Safe ordering — researcher inference, built on 1–6:**
   a. `kubectl -n kube-system annotate helmchart traefik-crd helmcharts.helm.cattle.io/unmanaged=true --overwrite`
      (same on `traefik` if you want the workloads left for a manual `helm uninstall`).
   b. Flip `--disable=traefik --disable=servicelb` and apply.
   c. Assert the 25 `traefik.io`/`hub.traefik.io` CRDs still exist **and** a `Middleware` still
      resolves, before the Flux release installs.
   d. Install the Flux Traefik on the upstream chart. Its CRDs come from `crds/`, and Helm
      **skips with a warning** when a CRD already exists — so pre-existing CRDs are reused, not
      replaced. Orphan-then-install is strictly safer than uninstall-then-install.
   **Confidence:** medium-high.

**VERDICT: Yes.** `--disable=traefik` disables the file that owns both HelmCharts, helm-controller
runs `helm uninstall` for both, and the CRDs go with the `traefik-crd` release unless orphaned
first. Highest-risk item in the cutover.

### Q2 — Is `servicelb` the valid token? What happens to existing `svclb-*` workloads?

1. **Claim:** `servicelb` is a valid `--disable` token. ServiceLB is implemented by k3s's embedded
   cloud provider (an `LBEnabled` config field), not by a bundled manifest, but it is accepted as
   a disable name "for historical reasons".
   **Sources:** [k3s docs](https://docs.k3s.io/installation/configuration),
   [`pkg/cloudprovider/cloudprovider.go`](https://github.com/k3s-io/k3s/blob/master/pkg/cloudprovider/cloudprovider.go).
   **Support:** direct. **Confidence:** high.
2. **Claim:** the controller provisions `svclb-<svc>-<hash>` DaemonSets/Pods whose `klipper-lb`
   containers take `hostPort` 80 and 443, and keeps a finalizer on the Service it provisions. With
   the controller not started, **nothing reconciles or garbage-collects those DaemonSets**.
   **Sources:** [`pkg/cloudprovider/servicelb.go`](https://github.com/k3s-io/k3s/blob/master/pkg/cloudprovider/servicelb.go);
   local spec `docs/superpowers/specs/2026-10-31-titan-ingress-ownership-decision.md` (klipper-lb
   hostPort 80/443; traefik the only LoadBalancer Service).
   **Support:** direct for controller shape; **interpretation** that no cleanup runs when the
   controller is simply not started. Exact finalizer string not verified. **Confidence:** medium-high.
3. **Claim (inference):** the failure mode is a black hole, not a port conflict. If both are
   disabled in one k3s restart, the `traefik` Service is deleted by helm uninstall while the
   orphaned `svclb-*` DaemonSet keeps binding host 80/443 and forwards to a Service that no longer
   exists. The new ClusterIP+externalIPs Traefik uses no hostPort, so it starts happily and
   receives nothing.
   **Action:** after apply, `kubectl -n kube-system get ds,pod | grep svclb-`, delete leftovers,
   then on the host `ss -lntp | grep -E ':80 |:443 '`.

**VERDICT: `servicelb` is correct.** Existing `svclb-*` DaemonSets are **not** cleaned up once the
controller is gone — delete them by hand and prove host ports 80/443 are free.

### Q3 — ClusterIP + externalIPs vs kube-proxy mode; k3s defaults; NixOS firewall

1. **Claim:** k3s **hardcodes** kube-proxy to `proxy-mode: iptables`. In
   `pkg/daemons/agent/agent_linux.go`, `kubeProxyArgs()` sets `"proxy-mode": "iptables"`; the only
   override is `--kube-proxy-arg proxy-mode=nftables` (or `ipvs`).
   **Sources:** [`agent_linux.go`](https://github.com/k3s-io/k3s/blob/master/pkg/daemons/agent/agent_linux.go),
   [k3s agent CLI](https://docs.k3s.io/cli/agent).
   **Support:** direct (source). **Confidence:** high.
   **Verify live:** `pgrep -af kube-proxy` on titan and read `--proxy-mode` — k3s runs kube-proxy
   in-process, so there is no DaemonSet to inspect.
2. **Claim:** upstream, `externalIPs` is a **deprecated** Service mechanism, and kube-proxy
   programs it in all three Linux modes (iptables / ipvs / nftables) as part of the per-Service
   rules it installs. `ipvs` mode is itself deprecated since v1.35.
   **Sources:** [Kubernetes, Virtual IPs and Service Proxies](https://kubernetes.io/docs/reference/networking/virtual-ips/).
   **Support:** direct for the deprecation and mode list; **interpretation** for "behaves
   identically in all modes" — the docs describe per-Service programming, not an
   externalIPs-per-mode matrix. **Confidence:** high for iptables (the k3s default), medium for
   nftables specifics. **A deprecated mechanism is being adopted as a permanent design — say so
   explicitly in the spec.**
3. **Claim:** kube-proxy's rules and a host firewall do not cooperate. k3s maintainer, verbatim:
   "We don't technically support k3s with firewalld enabled. Kubernetes makes extensive use of
   iptables rules and does not expect other products to be managing rulesets alongside it." On
   NixOS specifically, users report kube-proxy's iptables rules bypassing the module-managed
   firewall entirely.
   **Sources:** [k3s#11871](https://github.com/k3s-io/k3s/issues/11871),
   [NixOS Discourse](https://discourse.nixos.org/t/installing-k3s-disables-firewall-port-range-unexpectedly/46396).
   **Support:** direct (quoted maintainer + NixOS user report). **Confidence:** high.
   **Consequence:** do not enable firewalld. A NixOS `networking.firewall` deny on 80/443 may not
   stop externalIPs traffic at all, and a unit that flushes/reloads nftables can remove
   kube-proxy's chains. Treat the host firewall as non-authoritative for pod traffic and prove
   behaviour from off-node instead of by reading rules.
4. **Claim:** nftables-mode kube-proxy deliberately adds **no** firewall-accept rules for service
   ports (iptables mode does), so on an nftables-based host firewall you must allow the traffic
   yourself. k3s additionally needs the `nft` binary for that mode.
   **Sources:** [KEP-3866](https://www.kubernetes.dev/resources/keps/3866/),
   [Virtual IPs, "NodePort interaction with firewalls"](https://kubernetes.io/docs/reference/networking/virtual-ips/),
   [k3s#11267](https://github.com/k3s-io/k3s/issues/11267).
   **Support:** direct. **Confidence:** high. Only relevant if titan moves to `proxy-mode=nftables`.

**VERDICT: iptables mode, hardcoded by k3s, and externalIPs works there.** The NixOS
nftables/firewalld interaction is officially unsupported territory — do not enable firewalld;
verify externally. Flag the upstream externalIPs deprecation.

### Q4 — `externalTrafficPolicy: Local` vs `Cluster` with externalIPs on single-node

1. **Claim:** `externalTrafficPolicy` controls traffic "from external sources"; `Local` routes
   only to ready **node-local** endpoints and, if there are none, kube-proxy **drops** the traffic.
   `Cluster` routes to all ready endpoints and expects LB health checks on kube-proxy's
   `:10256/healthz`.
   **Sources:** [Kubernetes, Traffic policies](https://kubernetes.io/docs/reference/networking/virtual-ips/#traffic-policies).
   **Support:** direct (quoted). **Confidence:** high.
2. **Claim:** on one node, endpoint selection is identical under both policies — every endpoint is
   local. The difference that matters is masquerade: `Local` avoids the SNAT that the default
   policy applies to externally-arriving traffic, so Traefik sees the real client source IP.
   **Sources:** same page (the iptables section states that for NodePort/load-balancer ingress
   "the client IP address does get altered").
   **Support:** interpretation on direct doc text. **Confidence:** medium-high.
3. **Open — SO-UNVERIFIED:** whether kube-proxy applies `externalTrafficPolicy` on the externalIPs
   path specifically is **not stated** in the docs read; they frame the field around NodePort and
   LoadBalancer. Settle empirically: from an off-node host `curl -k https://<node-ip>/` with the
   policy set to `Local`, then `Cluster`, and read the source IP in Traefik's access log.
4. **Recommendation (researcher inference):** set `externalTrafficPolicy: Local`. No-op for
   routing on one node; it is what preserves client IPs. Record the footgun: the day a second node
   appears or the Traefik pod is unschedulable on that node, `Local` silently drops all traffic
   instead of load-balancing. **Confidence:** medium-high.

**VERDICT: use `Local`.** On single-node it changes only client-IP preservation, not routing;
verify the externalIPs path empirically because upstream docs are silent.

### Q5 — Traefik Helm chart values

1. **Claim:** `service.spec` is a **verbatim passthrough**. `traefik/templates/_service.tpl`
   defines `traefik.service-spec` as `toYaml .service.spec` followed by the chart's own selector,
   and `values.yaml` documents it as "Additional entries here will be added to the Service spec.
   Cannot contain selector or ports entries." Default is `service.spec.type: LoadBalancer`. The
   chart's own acceptance test sets `service.spec.externalIPs`, `externalTrafficPolicy`,
   `clusterIP` and `loadBalancerSourceRanges` there.
   **Sources:** [`_service.tpl`](https://github.com/traefik/traefik-helm-chart/blob/master/traefik/templates/_service.tpl),
   [`values.yaml`](https://github.com/traefik/traefik-helm-chart/blob/master/traefik/values.yaml),
   [`tests/service-config_test.yaml`](https://github.com/traefik/traefik-helm-chart/blob/e66342de/traefik/tests/service-config_test.yaml).
   **Support:** direct. **Confidence:** high. So:

   ```yaml
   service:
     spec:
       type: ClusterIP
       externalIPs: ["<NODE_IP>"]
       externalTrafficPolicy: Local
   ```

   k3s's own `valuesContent` already uses this shape (`service.spec.ipFamilyPolicy:
   PreferDualStack`), so the pinned chart supports it.
2. **Claim:** top-level `service.type` is **no longer read**. PR #1686, "fix(service)!: align
   syntax with upstream", is a breaking change that moved `type`, `externalIPs` and
   `ipFamilyPolicy` from `service.*` into `service.spec.*`.
   **Sources:** [traefik-helm-chart#1686](https://github.com/traefik/traefik-helm-chart/pull/1686).
   **Support:** direct. **Confidence:** high. Do not write the old shape from habit.
3. **Claim:** the websecure TLS switch is `ports.websecure.http.tls.enabled` and it is **already
   `true` by default** — there is no `ports.websecure.tls`. HTTP→HTTPS redirect is
   `ports.web.http.redirections.entryPoint: {to: websecure, scheme: https}`.
   **Sources:** [`values.yaml`, `ports` block](https://github.com/traefik/traefik-helm-chart/blob/master/traefik/values.yaml).
   **Support:** direct for the default; **interpretation** for the redirect stanza shape.
   **Confidence:** high / medium.
   **Follow-on (inference):** without a default certificate Traefik serves a fake one on
   websecure, so either per-Ingress `spec.tls` or a `tlsStore` default certificate referencing
   `titan-tls` — and that Secret must exist in Traefik's own namespace, which means adding it to
   the wildcard `secretTemplate` reflect-to allow-list per this repo's rule, never copying it.
4. **Claim:** dashboard/API off is `api.dashboard: false`. `api.insecure` defaults unset/false,
   `ingressRoute.dashboard.enabled` defaults `false`, and `ports.traefik.expose.default` is
   `false`, so the 8080 entrypoint is not in the Service to begin with. Keep the `traefik`
   entrypoint — liveness/readiness default to it.
   **Sources:** same `values.yaml` (`api`, `ingressRoute`, `ports.traefik`,
   `deployment.healthchecksPort`). **Support:** direct. **Confidence:** high.
5. **Claim:** the main chart ships CRDs in `traefik/crds/` — Helm-native handling: installed on
   first install, **never upgraded, never deleted**. The separate `traefik-crds` chart was
   deprecated at v38.0.2 and has been removed from the repository upstream.
   **Sources:** [README](https://github.com/traefik/traefik-helm-chart/blob/master/README.md)
   ("deprecated since v38.0.2"),
   [PR #1722 remove deprecated traefik-crds chart](https://github.com/traefik/traefik-helm-chart/pull/1722),
   [traefik/crds tree](https://github.com/traefik/traefik-helm-chart/tree/master/traefik/crds),
   [helm CRD best practices](https://helm.sh/docs/chart_best_practices/custom_resource_definitions/).
   **Support:** direct. **Confidence:** high. **Consequence:** the Flux release will never delete
   the CRDs, removing the uninstall hazard going forward — but CRD upgrades become a manual
   `kubectl apply`, and `vendor/cnpg-crds`-style vendoring here (`crd-check`) has no equivalent
   for Traefik, so nothing currently proves the live Traefik CRDs match the chart pin.
6. **Claim:** `values.schema.json` is generated from `.schema.yaml`, which sets
   `schemaRoot.additionalProperties: false`. **Unknown top-level values keys are rejected at
   `helm template` / `helm install`.** Many sub-blocks independently set
   `additionalProperties: false` (`api`, `autoscaling`, `core`, `providers` and children, `rbac`,
   `serviceAccount`, `hub`, `image`, `ingressClass`, `gatewayClass`, `podDisruptionBudget`,
   `readinessProbe`, `livenessProbe`, `updateStrategy`, `accessLog.filters`).
   **Sources:** [`.schema.yaml`](https://github.com/traefik/traefik-helm-chart/blob/master/traefik/.schema.yaml),
   [`values.schema.json`](https://github.com/traefik/traefik-helm-chart/blob/master/traefik/values.schema.json),
   [`values.yaml` `@schema` annotations](https://github.com/traefik/traefik-helm-chart/blob/master/traefik/values.yaml).
   **Support:** direct (`.schema.yaml` read in full; sub-block annotations read directly).
   **Confidence:** high. **Consequence:** `make chart-values-check` is exactly the right gate — a
   typo'd key fails the render, not the runtime.
7. **Two chart defaults that bite during cutover — researcher inference from direct defaults:**
   - `ingressClass.enabled: true`, `isDefaultClass: true`. The new release creates an IngressClass
     named after the release unless `ingressClass.name: traefik` is set. Two releases cannot both
     own `traefik`; if the old one is uninstalled first, the IngressClass disappears and every
     `ingressClassName: traefik` Ingress is unserved in the gap. Set `ingressClass.name: traefik`
     explicitly and install the new release **before** orphaning the old, or accept a window.
   - `providers.kubernetesIngress.publishedService.enabled: true` (k3s sets it too). With
     externalIPs, Traefik copies the Service's externalIP into Ingress `.status` — desirable.
   **Confidence:** medium-high.
8. **Pin — researcher inference, verify:** k3s's `40.1.4+up40.1.0` follows the
   `<k3s-revision>+up<upstream-version>` convention, so the parity pin is upstream chart `40.1.0`
   from `https://traefik.github.io/charts`, defaulting to Traefik 3.7.8. Confirm with
   `helm show values traefik/traefik --version 40.1.0 | grep -A3 '^image:'`. **Confidence:** medium.

**VERDICT: everything needed is supported**, all under `service.spec`, with
`ports.websecure.http.tls.enabled` already on, `api.dashboard: false` to close the dashboard,
chart-native `crds/` that Helm never deletes, and a root-strict `values.schema.json` that makes
`make chart-values-check` a real gate.

## Contradictions

- **`--disable=traefik` scope.** Community advice routinely reads it as "remove Traefik". The source
  says it disables the manifest file, which at this version also owns `traefik-crd`. The narrower
  reading is the one that silently destroys routing state.
- **`helm.sh/resource-policy: keep` reliability.** Helm docs present it as the supported way to
  survive an uninstall; [helm#10890](https://github.com/helm/helm/issues/10890) is an open report
  of it not being honoured on uninstall, with an unmerged fix (#10893). Do not design the plan
  around that annotation alone.
- **`unmanaged` annotation semantics.** Documented as "the chart is not updated"; whether it also
  suppresses the delete Job is the motivating claim in the original issue, not a stated guarantee.
- **externalIPs viability.** Kubernetes deprecates the mechanism; k3s, Traefik and countless
  single-node setups still use it. Both true — the spec should say which it is accepting.

## Missing evidence

- Whether k3s's `traefik-crd` chart sets `helm.sh/resource-policy: keep` on its 25 CRDs — must be
  read off the live cluster.
- Whether `helmcharts.helm.cattle.io/unmanaged` suppresses the uninstall Job on the
  helm-controller version bundled in `v1.35.8+k3s1`.
- Whether kube-proxy applies `externalTrafficPolicy` on the externalIPs path (docs silent).
- The exact Service finalizer string used by k3s's ServiceLB provisioner.
- Whether titan's NixOS `networking.firewall` currently affects pod-forwarded traffic at all —
  the NixOS report suggests kube-proxy's rules bypass it, but that is one user's observation.
- Whether upstream chart `40.1.0` exists at that exact version in the published index.

## Sources

Kept:
- k3s `manifests/traefik.yaml` @ tag v1.35.8+k3s1 — https://raw.githubusercontent.com/k3s-io/k3s/v1.35.8%2Bk3s1/manifests/traefik.yaml — proves both HelmCharts in one file; chart 40.1.4+up40.1.0; Traefik 3.7.8
- k3s `pkg/deploy/controller.go` — https://github.com/k3s-io/k3s/blob/master/pkg/deploy/controller.go — disable matching is by manifest basename
- k3s `pkg/daemons/agent/agent_linux.go` — https://github.com/k3s-io/k3s/blob/master/pkg/daemons/agent/agent_linux.go — `proxy-mode: iptables` hardcoded
- k3s `pkg/cloudprovider/cloudprovider.go` + `servicelb.go` — https://github.com/k3s-io/k3s/blob/master/pkg/cloudprovider/servicelb.go — ServiceLB provisioning and finalizers
- helm-controller `chart.go` — https://github.com/k3s-io/helm-controller/blob/master/pkg/controllers/chart/chart.go — OnRemove runs the uninstall Job
- helm-controller#127 — https://github.com/k3s-io/helm-controller/issues/127 — finalizer removal does not stop the uninstall
- k3s#5263 / k3s#5287 — https://github.com/k3s-io/k3s/pull/5263 — `helmcharts.helm.cattle.io/unmanaged`
- k3s docs, configuration — https://docs.k3s.io/installation/configuration — disabled AddOns are actively uninstalled
- Kubernetes, Virtual IPs and Service Proxies — https://kubernetes.io/docs/reference/networking/virtual-ips/ — proxy modes, externalTrafficPolicy semantics, externalIPs deprecation
- helm: CRD best practices, HIP-0011, `helm uninstall`, chart tips — https://helm.sh/docs/chart_best_practices/custom_resource_definitions/ , https://helm.sh/community/hips/hip-0011/ , https://helm.sh/docs/helm/helm_uninstall/ , https://helm.sh/docs/howto/charts_tips_and_tricks/
- traefik-helm-chart: `_service.tpl`, `service.yaml`, `values.yaml`, `.schema.yaml`, `values.schema.json`, `tests/service-config_test.yaml`, PR #1686, PR #1722, README
- k3s#11871 — https://github.com/k3s-io/k3s/issues/11871 — maintainer: firewalld unsupported
- NixOS Discourse — https://discourse.nixos.org/t/installing-k3s-disables-firewall-port-range-unexpectedly/46396
- KEP-3866 — https://www.kubernetes.dev/resources/keps/3866/ — nftables mode adds no firewall accepts

Deprioritized:
- DeepWiki pages on the Traefik chart — secondary summaries of files read directly.
- Rancher `partner-charts` VALUES.md — stale generated docs for chart 37.1.0.
- SpiffyEight77 blog, k3s discussion #10679 — assert the narrow "disable=traefik removes Traefik"
  reading that Q1 disproves.
- Roman Danko blog — kept only as corroboration for helm-controller#127, not independent authority.

## Next steps

1. Live check that decides whether orphaning is mandatory or merely prudent:
   `kubectl get crd middlewares.traefik.io -o jsonpath='{.metadata.annotations}{"\n"}{.metadata.ownerReferences}{"\n"}'`.
2. Scratch k3s at the same version: prove `unmanaged` prevents the uninstall Job, and that the 25
   CRDs plus a `Middleware` survive `--disable=traefik`.
3. Empirically settle Q4: off-node `curl` against the externalIP under each `externalTrafficPolicy`,
   reading the client IP in Traefik's access log.
4. `helm show values traefik/traefik --version 40.1.0` to confirm the parity pin, then
   `make chart-values-check` once the HelmRelease values are drafted.
