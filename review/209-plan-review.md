## Review

Target: `docs/superpowers/plans/2026-10-31-traefik-cutover-209.md` (963 lines) vs `docs/superpowers/specs/2026-10-31-titan-ingress-ownership-decision.md` and `review/209-preflight-findings.md`. No files edited.

### Correct — verified against the tree, not asserted

- **The `resource-policy` reasoning is used consistently.** §1.1 (plan:120-129) says helm reads `helm.sh/resource-policy` from the stored release manifest only, and **no later step quietly relies on the live annotation it just dismissed.** P1's "PASS (lucky)" branch (plan:199-203) correctly conditions on "the old chart rendered it, the annotation is *in the stored manifest*"; P1's footer (plan:206-208) forbids annotating live CRDs; T2's `service.annotations` (plan:503-504) is legitimate precisely because it is chart output. This is the single most common way a plan like this self-contradicts, and it does not.
- **The supervisor's two resolutions are reflected** where they matter: §1.2 (plan:138-161) and §8.3 (struck through) carry 15 objects / 14 hostnames / 13 built, and P3a/P6 are written for iptables. I independently confirmed the tree count: exactly 13 `kind: Ingress` documents across `apply/50-apps` + `apply/60-tesla`, 12 distinct hostnames, plus `sure` (`apply/50-apps/sure/sure.yaml:693` `className: traefik`) and `auth` (`apply/50-apps/auth/authentik.yaml:171`) = 14.
- **Tree-derived claims I could check all hold.** 3 `Middleware` (`apply/60-tesla/teslamate.yaml:174` `apps/teslamate-auth`, `apply/50-apps/llm/llm.yaml:295` `llm/bearer-auth`, `apply/50-apps/grafana/grafana.yaml:278` `observability/grafana-auth`), 1 `IngressRouteTCP` (`apply/60-tesla/fleet-telemetry.yaml:158`, `apps`, `entryPoints: [websecure]`), 5 `router.middlewares` refs, **all same-namespace** — the §1.2 claim is true. 9 `HelmRelease`s today → "10 of 10" after T2 is arithmetically right. 10 `kustomization.yaml` files. 9 vendored CRD files (4 CNPG + 2 flux + 1 cert-manager + 2 traefik). `vendor/traefik-crds/` really is `{middlewares.yaml, ingressroutetcps.yaml, VERSION}`.
- **`spec.install.crds` / `spec.upgrade.crds` really are in the vendored CRD** (`vendor/flux-crds/helmreleases.yaml:238`, `:475`), and `cert-manager.yaml:33` really does use `upgrade.crds: CreateReplace`. T1's "correction to the pre-flight" is sound as a statement of fact.
- **The dropped `prometheus.io/*` annotations are genuinely inert**: `docs/titan-metrics-scrape.md:1127` lists Traefik under "what is deliberately not scraped". The plan's "inert config is not parity" line is backed, not hand-waved.
- **Repo rules: no violations found.** No concrete public IPv4 in the plan (only `127.0.0.1`, allow-listed by the leak gate); no top-level `namespace:`; the single new manifest is explicitly listed in `apply/20-infra/kustomization.yaml` alongside the `reflector/`/`cnpg/` precedent; no Middleware moves namespace; §8.1 restates the no-attribution-trailer rule.
- **Ordering is stated** (§5) and the *reasoning* for "titan phase A first" is correct.

---

### P0 — will cause an outage or a false all-clear as written

**P0-1. §5 and §4/§6 contradict each other on the one question §5 exists to answer.**
`plan:789-796` orders: PR1 → C1 → **PR 2 (`nix` disable flags)** → PR 3 (phase B / address move). But §4 sequences C2=PR1, C3=PR3, C4=outage, **C5="land PR 2"**, and §6 hard-codes the opposite: C4's cost column says *"C4's forward path must be verified before C5 removes the ability to do it"* (plan:811) and C5's row says *"After C4 deleted the old Deployment/Service by hand…"* (plan:812).
This is not cosmetic. §6's C4 rollback — "re-create the old `Service type: LoadBalancer` in `kube-system` so ServiceLB re-provisions its DaemonSet" — **only works if `servicelb` is still enabled**, i.e. only in §4's order. An operator who follows §5 lands the nix flag first and silently voids the only rollback for the outage window.
**Fix:** swap rows 2 and 3 in §5 so the `nix` PR lands after C4, and add one line to §5 row 3 stating that C4's rollback depends on ServiceLB still being live.

**P0-2. The last command of the cutover can delete the IngressClass, has no exit check, and has no rollback row.**
`plan:746-751`: `helm -n kube-system uninstall traefik`, guarded only by the inline comment "the IngressClass is no longer its object". That claim is exactly what P3c leaves open (§8.4, plan:923-925): `verifyOwnershipBeforeDelete` is a helm-v4 behaviour. Under helm 3, uninstall deletes everything in the stored manifest regardless of live `meta.helm.sh/*` annotations — i.e. it deletes `IngressClass/traefik` **after all of §7 has gone green**, black-holing all 15 hostnames with a healthy Traefik pod. There is no command after line 751, no `Exit:` for it, and no §6 row.
**Fix:** after line 751 add a falsifiable exit — `kubectl get ingressclass traefik -o jsonpath='{.metadata.annotations}'` must still show `release-namespace: traefik-system`, and `helm -n kube-system list --all` must show only `traefik-crd` — plus a §6 row "old uninstall deleted the IngressClass → re-apply the class / force `flux -n traefik-system reconcile hr traefik --with-source`". If P3c came back UNKNOWN, make this step explicitly conditional on re-running the C3 adoption check first.

**P0-3. The `traefik-crd` release record is never deleted, so the plan's two CRD-safety claims are false.**
`plan:746-747` states the purpose: "delete the orphaned release records … so nothing later can `helm uninstall` its way into the CRDs", then deletes **only** `traefik` (plan:751, with the correct note "CRDs are not in this release"). The release that *does* own the 25 CRDs — `traefik-crd`, per preflight Q1.2 and plan:109-111 — is left installed and reachable forever. §6 C1 then asserts the opposite of reality: *"from C5 onwards the CRDs are safe because nothing can uninstall them"* (plan:807). `helm -n kube-system uninstall traefik-crd` remains a single command away from cascading every `Middleware` and the `IngressRouteTCP`, with `crd-check` and `ingress-auth` green.
**Fix:** either add `helm -n kube-system uninstall traefik-crd` to C4 *after* the CRDs are proven owned by nothing and re-applied from 41.1.1's `crds/` (so the uninstall has nothing to delete), or — safer — keep the record and replace both claims with an explicit, permanent note: "`traefik-crd`'s release record survives in `kube-system`; `helm uninstall traefik-crd` deletes the 25 CRDs and cascades the Middlewares. Do not run it." Add `helm -n kube-system list --all` to §7.2 step 2 so the surviving record is visible.

---

### P1 — fix before this is executed

**P1-1. §7.2's hostname loop omits the two chart-rendered hostnames — the exact blind spot §1.2 warns about.**
`plan:871-873`: `for h in authorize coder collabora files grafana investing-agent llm meals open-webui streaming tesla tesla-boards` — 12 hosts, i.e. exactly the tree-derived set. `auth` and `sure` are missing. Omitting `auth` is the worst case: authentik is the forwardAuth target, so step 6's three `302 to authentik` checks pass while every gated login is dead. §C4 (plan:716-719) correctly says "all 15"; the gate does not.
**Fix:** add `auth sure` to the loop, and derive the list from `kubectl get ingress -A -o jsonpath='{range .items[*]}{.spec.rules[*].host}{"\n"}{end}' | sort -u` rather than typing it — which is what plan:159-160 already demands ("Any future count of affected hostnames must come from `kubectl get ingress -A`").

**P1-2. `upgrade.crds: CreateReplace` mutates the 25 live CRDs inside the cutover window, and T1's exit is written to prove the opposite.**
T1 (plan:429-435) has the HelmRelease set `install.crds: Create` / `upgrade.crds: CreateReplace`. Flux applies `crds/` on **every upgrade**, so the PR-3 upgrade in C3 replaces the live 40.1.4-era CRDs with 41.1.1's — a live, cluster-scoped mutation landing mid-cutover, not "on every chart bump" later as the honest-limit sentence claims. Then T1's Exit (plan:436-437) is "after C4, `make update-crds` produces a diff of only `VERSION` (proving the live schemas are unchanged by the cutover)". If CreateReplace ran, that exit fails; if it passes, it proves CreateReplace did *not* take effect. The exit cannot mean what it says. And P5's "the 25 CRDs the new chart would install are exactly the 25 titan already has" (plan:345-348) is a **count** match, not a schema match — it does not license the reuse argument.
**Fix:** set `upgrade.crds: Create` for this HelmRelease (CRD refresh stays T1's explicit post-cutover `kubectl apply`), or move the replacement to its own pre-C3 step with its own check: diff 41.1.1's `crds/middlewares.yaml` + `ingressroutetcps.yaml` against `vendor/traefik-crds/` before C3 and state the delta. Rewrite T1's exit to name which of the two it is testing.

**P1-3. P2c's grep can never match, so the cross-namespace check passes vacuously.**
`plan:242-243`:
```
kubectl get ingress -A -o jsonpath='{...}{.metadata.annotations}{...}' | grep -o 'middlewares: [^ ]*'
```
`kubectl` renders a map as Go `map[k:v k2:v2]` — **no space after the colon**. The literal text produced is `router.middlewares:apps-teslamate-auth@kubernetescrd`, so `grep -o 'middlewares: [^ ]*'` (colon + space) matches nothing, ever. The PASS condition ("every reference's namespace prefix equals the Ingress's own namespace") is satisfied by an empty set and the FAIL condition can never fire. §1.2 (plan:165-167) says "P2c proves that rather than trusting this table" — it proves nothing. This is precisely the "gate that passes vacuously" AGENTS.md forbids.
**Fix:** `kubectl get ingress -A -o jsonpath='{range .items[*]}{.metadata.namespace}{" "}{.metadata.annotations.traefik\.ingress\.kubernetes\.io/router\.middlewares}{"\n"}{end}' | sort -u`, and make PASS explicit: every non-empty value's prefix must equal the namespace on the same line, **and** the output must contain 5 non-empty lines (matching the 5 refs in the tree). Also extend it to CR-side refs (`kubectl get ingressroute,ingressroutetcps -A -o jsonpath='{...spec.routes[*].middlewares...}'`), which is where a cross-namespace CR reference would actually live and which P2c never reads.

**P1-4. P2b's threshold is stale and contradicts §1.2/§8.3.**
`plan:235`: "This tree builds 13. If the cluster has 14, name the extra object." The resolved live count is **15**. An operator seeing 15 gets no trigger, and the PASS text ("the extra object", singular) doesn't describe the real state (two chart-rendered objects).
**Fix:** "PASS: `wc -l` prints **15**, and the two objects not built by the tree are `auth/authentik-server` and `sure/sure`, both `class: traefik`. FAIL: any other count, or an unnamed extra."

**P1-5. C1's Exit cannot fail.**
`plan:642-645` asserts the 25 CRDs "still print 25" and the Middleware "still resolves" immediately after annotating the HelmCharts — but nothing has triggered a deletion yet; the uninstall only fires when the flag lands in C5. The exit is a tautology, and the following line ("If this fails … do not continue into C2 on a cluster whose CRD survival is unproven") implies CRD survival was proven when it was not.
**Fix:** reduce C1's exit to "both annotations present on both HelmCharts" and state plainly that CRD survival is proven by P4 (scratch) and re-proven at C5 (live), where the check already sits (plan:767).

**P1-6. Two rollbacks restore from a record no step ever takes.**
§6 C4 (plan:811) re-creates the old LoadBalancer Service "from the P2a record"; §6 C5 (plan:812) re-applies the old Deployment/Service "from the P2a record". P2a (plan:216-221) is `helm list -A`, `kubectl get ingressclass -o wide`, `kubectl get clusterrole,clusterrolebinding` — it captures **neither the Deployment nor the Service**. The instruction to take them (`kubectl get deploy/svc -n kube-system -o yaml`) appears only in the C5 rollback cell, i.e. after the deletion it is needed for.
**Fix:** add a C0 step: `kubectl -n kube-system get deploy traefik svc traefik -o yaml > /tmp/kube-system-traefik-$(date +%F).yaml`, and make C0's Exit assert the file is non-empty and contains both `kind: Service` and `kind: Deployment`. Point §6 at that artifact.

**P1-7. P2a cannot be run with the identity §2 mandates.**
§2's preamble (plan:177-178) says use `k8s-reader` "except where a row says it cannot". P2a's first command is `helm list -A`, and helm stores release records as **Secrets**. `apply/20-infra/k8s-reader/clusterrole.yaml` deliberately omits `secrets` (and `docs/agent-read-access.md:20,74-75` makes that explicit). So the row that establishes "what the old release owns" is Forbidden. Same problem for C4's `helm uninstall`.
**Fix:** mark P2a (and C4's uninstall) "requires an admin context — `k8s-reader` is Forbidden on Secrets", the way §7.1 already does for `dry-run`.

**P1-8. Putting the HelmRelease in `apply/20-infra/` blocks every downstream stage if it goes red — unmentioned anywhere.**
`apply/00-bootstrap/stage-infra.yaml` sets `wait: true` and `timeout: 10m0s`; `stage-certificates.yaml` `dependsOn: infra`; `stage-apps.yaml` `dependsOn: certificates`. The manifest's own comment states the cost: "if cert-manager never goes Ready, certificates and apps stay blocked." A not-Ready Traefik HelmRelease therefore halts certificate renewals, every app, tesla, and the restic backups. And C3's documented failure mode — install refused with `AlreadyExists` (plan:700) — is exactly a not-Ready release. The plan never says this.
**Fix:** add a paragraph to T2 naming the blast radius, and give C3 a pre-flight escape hatch (e.g. `flux suspend hr traefik` before the ownership patch, or land the ownership patch and the values flip as two syncs so a refused adoption can be suspended out without holding `infra` red for 10 minutes).

**P1-9. C2's "verify internally" cannot detect the one thing phase A is for.**
The render-proof list (plan:557-565) enumerates args but **never asserts `--providers.kubernetesingress.ingress-class=traefik`**, and C2's exit (plan:660-663) is a curl whose pass condition is "404 from an unmatched router". A wrong ingress class also yields 404. With `api.dashboard: false` there is no API to query, so the phase-A verification would pass on a Traefik watching the wrong class — and the plan then hands over the IngressClass on the strength of it.
**Fix:** add to C2's exit: `kubectl -n traefik-system get deploy traefik -o jsonpath='{.spec.template.spec.containers[0].args}' | tr ' ' '\n' | grep ingress-class` must print `--providers.kubernetesingress.ingress-class=traefik`, and add that arg to the render-proof list.

---

### P2 — report-only

- **P3a passes vacuously** (plan:266-272). The plan itself says kube-proxy runs in-process, so `pgrep -af kube-proxy` matches nothing and "no `--proxy-mode` flag printed" is satisfied by the command finding nothing. Use the plan's own T3/C5 form: `ps -o args= -C k3s | tr ' ' '\n' | grep -i 'proxy-mode\|kube-proxy-arg'`.
- **P3c's PASS is not decidable from its own output** (plan:292-298). You cannot read the bundled helm version off a `klipper-helm` image tag. Fix: `crictl pull <image> && crictl run --rm <image> helm version`, or read `HELM_VERSION` from the image config.
- **T1's exit under-specifies the command's scope** (plan:436-437). `make update-crds` re-vendors **three** groups (`scripts/update-crds.sh` `CRD_GROUPS`: flux, cert-manager, traefik), so it rewrites three `VERSION` files and will also surface unrelated live drift in flux/cert-manager schemas — which is not "proof the live Traefik schemas are unchanged". Use `make update-crds` then `git checkout vendor/flux-crds vendor/cert-manager-crds` and diff only `vendor/traefik-crds`.
- **§8.9's F19 quote is not in this repo** (plan:942-946). `grep -r F19` returns only the plan's own two lines, and "two versions behind" matches nothing in `2026-10-30-vps-to-titan-workload-migration-design.md`. Either the quote is from `nix/` (say so) or the open question is invented.
- **nix spec citation lacks the `nix/` prefix** (plan:596-597): `docs/superpowers/specs/2026-10-01-ovh-single-node-k3s-design.md:52,:281` does not exist in this repo (checked `docs/superpowers/specs/`). Every other cross-repo path in the plan uses `nix/…`. Prefix it.
- **`releaseName` is left to the implementer while C3 hard-codes it** (plan:553-555 vs plan:685-686). C3 writes `meta.helm.sh/release-name=traefik`; if the implementer picks any other `releaseName`, adoption is refused and C3 falls to the bounded-gap path. Decide it here: state `releaseName: traefik` in T2's values block and cross-reference from C3.
- **`helm.sh/resource-policy: keep` on a Flux-owned Service carrying `externalIPs` is a latent black hole.** If the release is ever uninstalled, the Service survives with the node's address on it and no endpoints; under `externalTrafficPolicy: Local` kube-proxy drops rather than forwards. Phase A is safe (no externalIPs), but the plan adopts `keep` as permanent policy without stating that interaction. Either drop the annotation (Flux owns the release; `keep` is for resources meant to outlive it) or state the consequence next to it.
- **§3 says "two PRs"; §5 numbers four** (plan:398 vs plan:789-796). Renumber §3's heading.
- **The new `traefik-system` Namespace carries no pod-security decision.** Every sibling in `apply/00-bootstrap/namespaces.yaml` documents its PSS label choice (or its deliberate absence) with a reason. Add one line either way.
- **§8.10 is an unassigned defect** (plan:949-953). A committed plan citing an untracked `review/` file is the same class as an unlisted manifest. Give it to PR 1 or PR 4 explicitly.
- **One preflight "missing evidence" item was dropped silently**: the exact ServiceLB finalizer string (preflight, Missing evidence). C4 hedges the symptom ("if the LoadBalancer Service hangs on its finalizer") but §8 never lists it, so nobody owns confirming the string.

---

### Not verifiable from this workspace

No shell, no cluster, no `nix/` or `../k8s-techdelivery` checkout. I could not execute `make check-ci` / `make chart-values-check` to confirm §7.1's baseline numbers (40 objects / 9 vendored CRDs / 232 objects / 18 namespaces / 109 manifests / 10 kustomizations — the 9 and 10 halves I did confirm by enumeration), nor the §0.1 chart-render measurements, nor the k3s / helm / kube-proxy source citations. Those rest on the preflight's sourcing, which is cited to tagged files.

### Merge verdict

**BLOCK.** P0-1 through P0-3 are each a path to a self-inflicted outage or a false all-clear on a box whose failure mode is a black hole with a healthy pod, and all three are one-to-three-line text fixes. The plan's spine — orphan via `unmanaged`, prove it on scratch, phase A with no address, hand the class over, then move the address — is sound and unusually well-honest about its own unknowns; these are the holes in the runbook, not in the design.