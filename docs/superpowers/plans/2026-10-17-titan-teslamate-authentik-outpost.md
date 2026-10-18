# TeslaMate and Grafana behind authentik — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Require an authentik session for `tesla.titan.arrieta.eu` and `grafana.titan.arrieta.eu`, while Tesla's machine-facing endpoints — the Fleet public key, the OAuth callback and the mTLS telemetry intake — stay exactly as reachable as they are today.

**Architecture:** One authentik `ProxyProvider` in `forward_domain` mode, served by the **embedded** outpost inside the existing `authentik-server` process (no new workload, no new Secret). The provider is declared in a blueprint delivered as a plain ConfigMap, which is the chart's only declarative path. Traefik's `Middleware`/`IngressRoute` CRDs replace the two core `Ingress` objects, because a plain `Ingress` cannot express "forward-auth everything except `/.well-known`".

**Tech Stack:** authentik 2026.8.3 (already installed, `apply/50-apps/auth/authentik.yaml`), Traefik 3.7.8 CRDs (already installed), Flux HelmRelease values, kustomize. No new images, no new Secrets, no new namespaces.

**Spec:** `docs/superpowers/specs/2026-10-17-titan-teslamate-authentik-outpost-design.md` — read it alongside this plan. It carries the measured facts (§3), the field citations (§4) and the not-proven list (§8); this plan argues from it and does not repeat the reasoning.

## Global Constraints

- **Never set a top-level `namespace:` in a `kustomization.yaml`.** These trees span namespaces and that field rewrites them all.
- **Every file added under `apply/` must be listed in that directory's `kustomization.yaml`.** `make kustomize-listing` enforces it; an unlisted manifest builds green and is silently never applied.
- **No `kind: Secret` outside `apply/10-secrets/`.** This plan adds a **ConfigMap**, not a Secret — `make secrets-placement` must stay green without being edited.
- **`Ingress` and `IngressRoute` for the same host+prefix must never coexist.** Delete and add in one commit. Rollback is `git revert` of that commit, which Flux reconciles back.
- **`make crd-check` does not validate Traefik CRDs** — it only knows `vendor/cnpg-crds/`. `make dry-run DRYRUN_CONTEXT=<admin context>` is the only gate that will catch a mis-nested `IngressRoute` field, and it is mandatory in Tasks 3 and 4, not optional.
- **Order matters.** The blueprint must be applied and proven (Task 2) before any route points at it (Tasks 3-4). A route pointing at a provider that does not exist fails closed: every request to TeslaMate breaks, including for the owner.
- **`git add -A` then `make check` before any commit**, per AGENTS.md. `*.dump` is gitignored since PR #59; do not re-add it.

---

## Task 0: read the model names and the outpost path out of the running container

Nothing is written in this task. It exists because the coder blueprint's own header records that a
wrong blueprint model name fails validation in the worker's log and nowhere else, and because the
spec's §8 lists both of these as unproven.

**Files:** none (probe only)

- [x] **Step 1: exact blueprint model strings** — ran; output below. All three guesses were right,
  and one of them turned out to be unusable for a reason no model string could reveal (see Task 1).

```
MODEL authentik_outposts.outpost
MODEL authentik_outposts.outpostserviceconnection
MODEL authentik_providers_proxy.proxyprovider
```

```bash
kubectl --context titan -n auth exec deploy/authentik-worker -- ak shell -c \
  'from authentik.outposts.models import Outpost, OutpostServiceConnection
from authentik.providers.proxy.models import ProxyProvider
for m in (Outpost, OutpostServiceConnection, ProxyProvider):
    print(f"{m._meta.app_label}.{m._meta.model_name}")'
```

Expected: three lines of the form `authentik_outposts.outpost`,
`authentik_outposts.outpostserviceconnection`, `authentik_providers_proxy.proxyprovider`. **Use what
it prints, not what is written above** — the spec lists those as a guess to be retired.

- [x] **Step 2: does the embedded outpost answer, and on what path** — `OUTPOST 404`, recorded as the
  baseline. What the 404 actually meant was only established later: the embedded outpost already exists
  (`embedded_outpost()` in `outposts/apps.py`, `managed=goauthentik.io/outposts/embedded`, type proxy)
  and serves this path, but its provider list was empty — confirmed live:
  `OUTPOST 'authentik Embedded Outpost' managed= 'goauthentik.io/outposts/embedded' type= proxy providers= []`.
  A 404 from an outpost with no providers is a different diagnosis from "no outpost exists", and the
  two lead to completely different manifests.

```bash
kubectl --context titan -n auth exec deploy/authentik-worker -- \
  curl -s -o /dev/null -w '%{http_code}\n' \
  http://authentik-server.auth.svc.cluster.local/outpost.goauthentik.io/auth/traefik
```

Expected before any provider exists: `404`. After Task 2 it must change to an auth challenge
(`401`/`407`). Record the before value; a code that never changes means the path is wrong and Task 3
would fail closed.

- [x] **Step 3: record both outputs** — recorded inline above rather than in a separate progress file,
  because the two results are only meaningful next to the correction they caused.

---

## Task 1: the blueprint, as a ConfigMap

**Files:**
- Create: `apply/50-apps/auth/tesla-outpost-blueprint.yaml`
- Modify: `apply/50-apps/kustomization.yaml`
- Modify: `apply/50-apps/auth/authentik.yaml` (HelmRelease values + worker reloader annotation)

**Three corrections to this task, all found by reading source or by the live apply rather than trusting
the plan.** They are kept here rather than quietly fixed, because the wrong version is the kind of thing
that gets re-derived from scratch by the next person.

1. **There is no `apply/50-apps/auth/kustomization.yaml`.** The stage lists its files directly in
   `apply/50-apps/kustomization.yaml`; `auth/`, `coder/`, `databases/` and `tesla/` have no per-directory
   kustomization at all. Step 2 below names the right file.
2. **No `ServiceConnection`, and no new `Outpost`.** The entry this plan specified cannot be written:
   `OutpostServiceConnection` is not a `SerializerModel` (`outposts/models.py:121` — only the Docker and
   Kubernetes subclasses are, `:181` and `:232`) and it sits in the blueprint importer's excluded list
   (`blueprints/v1/importer.py:80`, checked at `:91`). Proven, not inferred: a pre-flight `validate()`
   against the live instance rejected it with `Model <class 'authentik.outposts.models.OutpostServiceConnection'> not allowed`.
   The embedded outpost needs neither — `Outpost.service_connection` is `null=True` with the help text
   "Leave empty if authentik should not handle the deployment" (`models.py:271-280`), and the managed
   embedded outpost is editable by design: `validate_name` freezes only its name and `validate_providers`
   returns early for it (`outposts/api/outposts.py:60-90`). So the blueprint attaches a provider to the
   outpost authentik already made, and thereby **owns that outpost's provider list** — a provider added
   in the UI is removed by the next apply. That consequence is written in the ConfigMap's own header.
3. **`authorization_flow` and `invalidation_flow` are required and were missing.** The first live apply was
   rejected: `Entry invalid: Serializer errors {'authorization_flow': ['This field is required.'],
   'invalidation_flow': [...]}`. Both are required on the `Provider` base with no default; everything else
   inherited from `OAuth2Provider` has one (`client_id` is `default=generate_id` at
   `providers/oauth2/models.py:233-238`, `client_secret` and `logout_uri` are `blank=True`, `signing_key`
   and `encryption_key` are `null=True`), and because DRF reports every failing field in a single pass the
   two named were the complete set rather than the first of several rounds. Both are resolved with `!Find`
   against the shipped flow slugs, and both slugs were confirmed present on this cluster rather than assumed.

- [x] **Step 1: write the ConfigMap.** Key `tesla.yaml` (the chart only discovers keys ending in
  `.yaml`, per the values comment). Two entries:

  - `authentik_providers_proxy.proxyprovider` — `id: titan-tesla-provider`, `name: titan-tesla`,
    `external_host: https://titan.arrieta.eu`, `mode: forward_domain`,
    `cookie_domain: titan.arrieta.eu`, `skip_path_regex: '^/\.well-known'`. `internal_host` is left
    unset rather than set to `""`: the field's help text marks it exclusive to the non-forward modes
    (`providers/proxy/models.py:87-94`).
  - `authentik_outposts.outpost` — identified by `name: authentik Embedded Outpost`, i.e. the managed
    one, with `type: proxy` and `providers: [!KeyOf titan-tesla-provider]`. `type` must be present in
    attrs: `validate_providers` dispatches on `initial_data["type"]` (`outposts/api/outposts.py:69-88`).

  Header comment must say, in the repo's voice: why a ConfigMap and not a Secret (no credentials, and
  the chart offers only `blueprints.configMaps` / `blueprints.secrets` — `values.yaml:220-226` of
  authentik-2026.8.3, no inline entries), and what `skip_path_regex` is protecting (Tesla's fetch of
  the Fleet public key, which presents as "application has not registered" when it 404s).

- [x] **Step 2: list it** in `apply/50-apps/kustomization.yaml`, before `auth/authentik.yaml` — the
  HelmRelease mounts this ConfigMap, and a pod whose mount target does not exist yet sits Pending. Forgetting
  this is the failure mode `make kustomize-listing` exists for; it now reports 52 manifests, 0 unlisted.

- [ ] **Step 3: wire the HelmRelease.** In `apply/50-apps/auth/authentik.yaml` values:

```yaml
    blueprints:
      configMaps:
        - authentik-tesla-blueprint
```

  and add `configmap.reloader.stakater.com/reload: authentik-tesla-blueprint` beside the existing
  `secret.reloader.stakater.com/reload` on the **worker only**. The plan said both; the file's own
  comment at `authentik.yaml:105-110` says the server does not apply blueprints and restarting it for a
  blueprint edit would be an auth outage for no behaviour. That reasoning is correct and it wins.
  Without the worker annotation, an edit to this ConfigMap sits unread for up to an hour, which is the
  exact reason the existing annotation was added.

- [x] **Step 3b: pre-flight the blueprint against the live instance, without writing anything.**
  `Importer.from_string(...).validate()` runs the entire import inside a rolled-back transaction
  (`blueprints/v1/importer.py:453-474`), so it reports model and field errors and changes nothing:

```bash
kubectl --context k8s-titan -n auth exec -i deploy/authentik-worker -- sh -c 'cat > /tmp/tesla.yaml' < /tmp/tesla.yaml
kubectl --context k8s-titan -n auth exec deploy/authentik-worker -- ak shell -c 'from authentik.blueprints.v1.importer import Importer; imp = Importer.from_string(open("/tmp/tesla.yaml").read()); ok, events = imp.validate(raise_validation_errors=False); print("VALID", ok); [print("EVENT", e) for e in events]'
```

  Write it as one line with `;` separators: `ak shell -c` takes the string verbatim, and a multi-line
  paste through a shell continuation prompt arrives indented and dies with `IndentationError`.
  This gate is optional — a bad blueprint cannot lock anyone out before Task 3, because no route points
  at the provider yet, and the worker log says so — but it caught the excluded-model error above for the
  price of one command. It needs `pods/exec`, which `k8s-reader` does not have in `auth`; reading the
  worker log afterwards does not, which is why the post-merge half of this plan is runnable by the agent.

- [x] **Step 4: verify offline**

```bash
git add -A && make check
```

Expected: `kustomize-listing: ... 0 unlisted, 0 listed-but-missing`, `secrets-placement` clean (a
ConfigMap is not a Secret), `crd-check` unchanged (it does not know Traefik or HelmRelease-internal
objects).

- [ ] **Step 5: commit** `auth: declare the Tesla apps in authentik, as a blueprint ConfigMap`.

---

## Task 2: prove the outpost endpoint answers before anything depends on it

**Where a blueprint failure actually gets written.** Not stdout. `blueprints/v1/tasks.py:211-222` calls
`self.logs(logs)` on failure, so the importer's warnings become `TaskLog` rows (`tasks/models.py:181-198`,
`related_name="tasklogs"`) on the `apply_blueprint` task whose `_uid` is the slugified blueprint name.
`kubectl logs` on the worker shows a clean run for a blueprint that was rejected. Two queries, both
read-only but both needing `pods/exec`, which `k8s-reader` does not have in `auth`:

```bash
# was it discovered, and did it take? status is one of successful | warning | error | orphaned
kubectl --context k8s-titan -n auth exec deploy/authentik-worker -- ak shell -c 'from authentik.blueprints.models import BlueprintInstance; [print(b.name, "|", b.path, "|", b.status, "|", b.last_applied) for b in BlueprintInstance.objects.all()]'
# why not, if it did not
kubectl --context k8s-titan -n auth exec deploy/authentik-worker -- ak shell -c 'from authentik.tasks.models import Task; [print(t._uid, t.state, "|", l.log_level, "|", l.event) for t in Task.objects.filter(_uid="titan-tesla") for l in t.tasklogs.all()]'
```

The field names are `_uid` and `state`, not `uid` and `status` — a wrong guess fails with a `FieldError`
that dutifully lists the real ones. The `path` column also settles a question no log answers: mounted
blueprints land at `mounted/cm-<configMap>/<key>.yaml` and `mounted/secret-<secret>/<key>.yaml`, which is
how you tell "the mount is wrong" from "the blueprint is wrong". A `BlueprintInstance` row with
`status=error` is discovered-and-rejected; no row at all is never-discovered. Those are different
diagnoses with different fixes, and only this table distinguishes them.

**Why the outpost endpoint cannot be probed the obvious way.** The embedded outpost is dispatched by the
Rust server inside authentik-server: `route_core_and_outpost` (`src/server/mod.rs:260-289`) resolves the
provider with `app_for_request(&host, uri)` and falls through to Django when nothing matches, which is
where a `404` comes from. Two consequences, both measured here rather than read off a diagram:

1. Host resolution prefers `X-Forwarded-Host` over `Host`
   (`packages/ak-axum/src/extract/host.rs:13, 52-59`). That is what makes Traefik `forwardAuth` work at
   all: Traefik sets XFH to the original request's host, so a forward request for
   `tesla.titan.arrieta.eu` resolves the provider even though the connection goes to the authentik
   Service.
2. The same header is why a hand-made probe is worthless. Traefik rewrites `X-Forwarded-Host` on inbound
   requests, so
   `curl -H 'X-Forwarded-Host: tesla...' https://auth.titan.arrieta.eu/outpost.goauthentik.io/auth/traefik`
   arrives with XFH `auth.titan.arrieta.eu`, matches no provider, and 404s — identically whether or not
   the provider exists, and identically to a control request for a host that does not exist. **This
   endpoint is not a usable pre-Task-3 signal.** The first request that can reach it is Task 3's own
   route, so the `404 -> challenge` test belongs there, not here.

What Task 2 can prove is the two queries above, and both need `pods/exec` in `auth`, which `k8s-reader`
does not have. They are operator commands; everything else in this task is agent-readable.

**Files:** none

- [x] **Step 1: apply and wait for the worker.** Done, and the agent can watch all of it except the
  blueprint outcome: `apps` moved to the merged revision, the ConfigMap `resourceVersion` changed, and
  Stakater's reloader rolled the worker (`authentik-worker-5bcf6b95c-cfr5s` → `authentik-worker-5d99f6f948-85758`)
  without anyone touching it — which is the annotation from Task 1 doing its job. `blueprints_discovery`
  ran and reported `Task finished, exc: null`, **and that line means nothing**: the rejected blueprint in
  the previous section reported exactly the same thing.

```bash
kubectl --context titan -n flux-system logs deploy/kustomize-controller --since=5m | grep -i authentik
kubectl --context titan -n auth logs deploy/authentik-worker --since=5m | grep -iE "blueprint|titan-tesla|error"
```

Expected: the blueprint is applied with no validation error. A wrong model name or attribute shows
**only here** — no Kubernetes object reflects it.

- [x] **Step 2: re-run Task 0 Step 2.** **Retired, not passed.** The endpoint cannot distinguish the two
  states from outside — see the dispatch note above: Traefik rewrites `X-Forwarded-Host`, so every probe
  arrives with the front door's own host, matches no provider, and 404s whether or not the provider
  exists. A control request for a host that does not exist returns the same code. The plan's "if it is
  still `404`, the path is wrong" would have sent the next person chasing a phantom; the first request
  that can reach the outpost is Task 3's own route.

- [x] **Step 3: confirm authentik actually has the objects.** This is the only real proof Task 2 has,
  and it needs `pods/exec` in `auth`:

```bash
kubectl --context k8s-titan -n auth exec deploy/authentik-worker -- ak shell -c 'from authentik.blueprints.models import BlueprintInstance; from authentik.outposts.models import Outpost; [print(b.name, "|", b.status) for b in BlueprintInstance.objects.filter(name="titan-tesla")]; [print(o.name, list(o.providers.values_list("name", flat=True))) for o in Outpost.objects.all()]'
```

  Live output after the second merge:

```
titan-tesla | successful
authentik Embedded Outpost ['titan-tesla']
```

  Which is also the record that the first merge did **not** work: the same query returned
  `titan-tesla | error` with `authentik Embedded Outpost []`, and the reason was two required provider
  fields, not anything about the outpost.

```bash
kubectl --context titan -n auth exec deploy/authentik-server -- ak shell -c \
  'from authentik.providers.proxy.models import ProxyProvider
from authentik.outposts.models import Outpost
for p in ProxyProvider.objects.filter(name="titan-tesla"):
    print(p.name, p.mode, p.cookie_domain, repr(p.skip_path_regex))
for o in Outpost.objects.filter(name="titan-tesla"):
    print(o.name, o.type, list(o.providers.values_list("name", flat=True)))'
```

Expected: `titan-tesla forward_domain titan.arrieta.eu '^/\\.well-known'` and
`titan-tesla proxy ['titan-tesla']`. If `skip_path_regex` prints empty, the blueprint wrote a
different attribute name — fix it here, not after the routes exist.

---

## Task 3: TeslaMate's front door

**Files:**
- Modify: `apply/50-apps/tesla/teslamate.yaml` (delete the `Ingress`, add `Middleware` + `IngressRoute`)
- Modify: nothing else; `wellknown.yaml` stays as it is and must keep working untouched

- [ ] **Step 1: capture the public key's current body hash**, so "unchanged" is a comparison and not
  an impression:

```bash
curl -s https://tesla.titan.arrieta.eu/.well-known/appspecific/com.tesla.3p.public-key.pem | sha256sum
```

- [x] **Step 2: write the `Middleware`.** `forwardAuth` with `address` the embedded outpost
  (`http://authentik-server.auth.svc.cluster.local/outpost.goauthentik.io/auth/traefik` — that Service is
  `80 -> 9000`, measured, and 9000 is the Rust server that dispatches the outpost path) and
  `trustForwardHeader: true`. **`authResponseHeaders` is deliberately unset.** The plan said to forward
  `X-Forwarded-User`/`-Email`/`-Preferred-Username`/`-Groups`; that is the legacy nginx-auth-proxy set and
  authentik does not emit it — authentik's own Traefik-3 generator forwards the `X-authentik-*` set
  (`providers/proxy/controllers/k8s/traefik_3.py:124-145`). Neither TeslaMate nor Grafana reads any
  identity header, so nothing is forwarded: forward-auth here is a gate, not an identity handoff, and an
  app that has no use for a JWT should not be sent one.

- [x] **Step 3: attach the `Middleware` to the existing `Ingress` by annotation** —
  `traefik.ingress.kubernetes.io/router.middlewares: apps-teslamate-auth@kubernetescrd`. The plan said to
  replace the `Ingress` with an `IngressRoute`; that was rejected on precedence. Today `/.well-known`
  (wellknown.yaml) and `/` are both plain Ingresses and Traefik's ordering between them is proven in
  production by Tesla's own daily fetch. Moving only one side to an IngressRoute puts the two routers in
  different providers with different default-priority arithmetic, and if the catch-all ever wins, the
  public key starts 404ing and pairing reports "application has not registered" — the single failure mode
  this whole tree is arranged to avoid. Same provider, same ordering, two-line diff.

  Note what that ordering is actually load-bearing for: the public key is served by a **different router
  with no middleware attached**, so the forward-auth call is never made for it. `skip_path_regex` in the
  blueprint is a backstop, not the mechanism.

  > **CORRECTION — read this before trusting anything written on 2026-10-18 about the suffix.**
  >
  > PR #64 merged claiming `@kubernetes` was "the only spelling that resolves" on traefik 3.7.8 and that
  > `@kubernetescrd` was a v2 leftover. **That is false, and it is in main's commit message.** Traefik's
  > own source says otherwise: `ProviderName = "kubernetescrd"` (`pkg/provider/kubernetes/crd/kubernetes.go:47`,
  > tag v3.7.0). The original annotation was correct.
  >
  > The evidence I "quoted" for the change — a log line reading `middlewareName=apps-teslamate-auth@kubernetes`
  > — does not exist in the log. The real line reads `@kubernetescrd`. I re-read my own summary instead of
  > the log and shipped a change on that, which is how a working config got replaced by a broken one while
  > the outage was already open.
  >
  > **What was actually wrong** was never the suffix. The proxy provider had no `Application`, and the
  > endpoint the embedded outpost uses to enumerate its providers filters those out:
  > `ProxyProvider.objects.filter(application__isnull=False)` (`authentik/providers/proxy/api.py:184-188`).
  > Empty list, no apps, every host falls through to the core router, 404. The outpost then suppresses its
  > own empty-provider warning for embedded outposts (`src/outpost/proxy/mod.rs:129`), so there was nothing
  > to read anywhere. Traefik was faithfully forwarding authentik's 404 the entire time.
  >
  > Ruled out by measurement before that conclusion: `k8s-reader` could not read `traefik.io` (fixed in #65),
  > the outpost service account's permission on the provider (`True`), `mode`/`cookie_domain` (both correct,
  > and `host.ends_with(cookie_domain)` matches `tesla.`), and a full `authentik-server` restart (changed
  > nothing, which is what killed the stale-cache theory).
  >
  > The annotation is therefore `@kubernetescrd`, and the fix is the `authentik_core.application` entry in
  > `apply/50-apps/auth/tesla-outpost-blueprint.yaml`.

- [ ] **Step 4: dry-run — mandatory, because `crd-check` cannot see Traefik schemas**

```bash
make dry-run DRYRUN_CONTEXT=<admin context>
```

- [ ] **Step 5: commit, push, let Flux apply, then run the three checks that decide it**

```bash
# must be 200 and the same hash as Step 1 — Tesla's fetch path, no cookie
curl -s -o /dev/null -w '%{http_code}\n' https://tesla.titan.arrieta.eu/.well-known/appspecific/com.tesla.3p.public-key.pem
curl -s https://tesla.titan.arrieta.eu/.well-known/appspecific/com.tesla.3p.public-key.pem | sha256sum
# must redirect to auth.titan.arrieta.eu
curl -s -o /dev/null -w '%{http_code} %{redirect_url}\n' https://tesla.titan.arrieta.eu/
```

- [ ] **Step 6: the human checks.** Sign in through authentik, then confirm the dashboard updates
  (that is the websocket surviving forward auth — spec §8) and that no 401 loop appears in the
  browser network tab. If the websocket loops, the fallback is a route for `/ws` without the
  middleware — but only after confirming TeslaMate's `/ws` has no data worth protecting on its own.

- [ ] **Step 7: if anything failed**, `git revert` the commit and let Flux restore the `Ingress`.
  Do not hand-edit live objects: Helm/Kustomize drift here is permanent by design
  (AGENTS.md, drift paragraph).

---

## Task 4: Grafana's front door, and the iframe

**Files:**
- Modify: `apply/50-apps/tesla/grafana.yaml` (same swap: `Ingress` → `Middleware` + `IngressRoute`)

- [ ] **Step 1: reuse the middleware** from Task 3 if it is namespace-local, or duplicate it —
  Traefik `Middleware` is namespaced, and both apps live in `apps`, so one middleware serves both.

- [ ] **Step 2: replace the `Ingress`** for `grafana.titan.arrieta.eu` the same way. `Grafana`'s
  `GF_SERVER_ROOT_URL` is already `https://grafana.titan.arrieta.eu/` with
  `GF_SERVER_SERVE_FROM_SUB_PATH=true` (`grafana.yaml:68-70`), so no Grafana-side change is needed.

- [ ] **Step 3: dry-run, commit, apply**, then:

```bash
curl -s -o /dev/null -w '%{http_code} %{redirect_url}\n' https://grafana.titan.arrieta.eu/
```

- [ ] **Step 4: the cookie test that decides `forward_domain` was right.** With one cookie jar, sign
  in once and fetch both hosts:

```bash
curl -s -c /tmp/jar -b /tmp/jar -L -o /dev/null -w 'tesla   %{http_code}\n' https://tesla.titan.arrieta.eu/
curl -s -c /tmp/jar -b /tmp/jar -o /dev/null -w 'grafana %{http_code}\n' https://grafana.titan.arrieta.eu/
```

Expected: the second call is `200` or a same-origin redirect, **not** a fresh redirect to
`auth.titan.arrieta.eu`. If it redirects, `forward_domain` did not produce a shared cookie and the
fallback is two `forward_single` providers — record that in the spec's §8 rather than leaving it in
this plan.

- [ ] **Step 5: the iframe test.** In a signed-in browser, open a drive's Grafana view from inside
  TeslaMate and watch the network tab. This is the measurement that retires the spec's
  "same-site by arithmetic" claim.

---

## Task 5: make the invariant a gate

**Files:**
- Create: `scripts/tesla-outpost-check.sh`
- Modify: `Makefile`

- [ ] **Step 1: write the script.** It asserts, from outside the cluster, that the two things which
  must never regress hold: the public key is reachable **without a cookie** and hashes to the value
  recorded in Task 3 Step 1, and `/` on both protected hosts redirects to `auth.titan.arrieta.eu`.
  It must **skip out loud** when the hosts are unreachable — same rule as `make dry-run`, which skips
  rather than passing vacuously when there is no admin context. A gate that passes because it could
  not reach anything is worse than no gate.

- [ ] **Step 2: wire it into `check` and not `check-ci`.** It needs network to the live cluster, which
  CI does not have — the same division that keeps `validate` and `dry-run` out of `check-ci`.

- [ ] **Step 3: prove it fails when it should.** Temporarily point the expected hash at a wrong value
  and confirm non-zero exit; then revert. A gate that has never been seen to fail is not evidence.

---

## Task 6: write it down

**Files:**
- Modify: `docs/teslamate-runbook.md`
- Modify: `docs/superpowers/specs/2026-10-17-titan-teslamate-authentik-outpost-design.md`

- [ ] **Step 1: runbook.** A new section covering: what is behind authentik and what is deliberately
  not; the lockout rollback (`git revert`, never `kubectl edit`); the fact that **the car's upload
  path does not depend on authentik** and why that matters when authentik is down; and the new
  symptom in troubleshooting — a TeslaMate that will not load is now possibly an authentik problem,
  which it was not before.

- [ ] **Step 2: spec §8.** Move each row to proven or leave it not-proven with what stopped it. Do
  not delete a row without saying which test retired it; the table is the point of the document.

- [ ] **Step 3: `git add -A && make check`, commit, branch, PR.** Pushing needs the operator's
  explicit go-ahead, per AGENTS.md.
