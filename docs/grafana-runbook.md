# titan Grafana — what it shows, what it cannot show, and what to do when it stops

Design and every declined alternative:
`docs/superpowers/specs/2026-10-21-titan-grafana-design.md`. This file is the operational half: the
commands, the failure modes, and the panels that are empty on purpose.

Status: the manifests are in this repo. Nothing here is live until the change is on `main`, because
Flux syncs `main`.

## 1. What this is

A Grafana in namespace `observability`, host `grafana.titan.arrieta.eu`, that is the **homelab's**
pane of glass rather than titan's dashboard. It reads k8s-casa's Prometheus and k8s-casa's Loki over
the OPNsense WireGuard mesh. **titan runs neither.** There is no Prometheus on titan and none is
planned, for the reasons in `docs/titan-metrics-scrape.md`.

| | |
|---|---|
| Prometheus | `https://prometheus.local.arrieta.eu` — casa's, over the mesh |
| Loki | `https://loki.local.arrieta.eu` — casa's, the same host promtail pushes titan's pod logs to (`docs/titan-logs-loki.md`) |
| Dashboards | seven, copied from `k8s-casa/apply/50-apps/casa/grafana-dashboards/`, provisioned from ConfigMaps |
| Edge gate | **none at the proxy** — authentik OIDC in-app, plus the two group bindings on the `observability` application (§4, §10) |
| Identity | authentik OIDC, application slug `observability` |
| Local admin | `Secret/observability/observability-grafana-admin`, kept as the escape hatch |

## 2. The dependency no manifest shows

Both datasources are **unauthenticated today**, and Grafana proxies them **server-side** — it has no
browser session to present. Measured, not assumed: `/-/ready` → 200 and `count(up)` → 106 with no
credentials, from a titan workspace.

So if casa ever puts `prometheus.local.arrieta.eu` behind authentik — the way
`prometheus.home.arrieta.eu` already is — **every panel goes empty at once** and the pod stays
healthy throughout. The datasource test is the first place it shows:

```sh
curl -sS -G https://prometheus.local.arrieta.eu/api/v1/query --data-urlencode 'query=count(up)'
```

A JSON body with a number means the path is intact. A 302 to `auth.*` or a login page means casa
changed the exposure and this Grafana needs a credential, not a restart.

## 3. What each dashboard actually shows

The datasource is shared across three clusters. `count by (cluster) (up)` returns **94 targets with
no `cluster` label** (casa's own), **7 with `cluster="titan"`**, **5 with `cluster="techdelivery"`**.
That is the whole-homelab view the design chose deliberately, and `cluster` is *not* a usable filter:
titan's own `node_exporter` (`192.168.133.1:9100`) and comin (`:4243`) scrapes carry no `cluster`
label at all, while its k8s scrapes do.

| board | reads | what you actually get |
|---|---|---|
| node-exporter | `node_*` | all 17 exporters in the homelab, titan among them; `instance` is a query variable listing them |
| disk | `node_filesystem_*` | same set; 9 filesystems on titan |
| comin | `comin_*` | 13 devices including `192.168.133.1:4243` |
| postgres | `pg_*` filtered on `service="postgres-exporter"` | **casa's database.** titan's CNPG databases are **not** here — CNPG's exporter is not scraped into this Prometheus. This is a gap in the metrics pipeline, not a broken board |
| amdgpu | `node_drm_*`, plus the `llamacpp:*` panels for the halogen backend (`Generation TPS`, `Prompt TPS`, `Tokens generated/s`, `Requests deferred / processing`, `KV cache tokens`) | whatever has a GPU; the metric family exists with one series. The LLM panels resolve on the shared Prometheus through the `casa-halogen` scrape |
| alerts | `alertmanager_*` | casa's Alertmanager. titan runs none |
| security-scans | `kube_job_status_*` + Loki log lines | casa's scan jobs. titan's pod logs are in the same Loki under `cluster="titan"`, but no titan job runs these scans, so the Findings rows are thin by construction |

An empty panel on `postgres`, `alerts` or `security-scans` is expected. The point of this table is
knowing which empties are on purpose.

## 4. Login

**One gate, not two — since 2026-11-05.** There used to be a Traefik forwardAuth Middleware in front
of Grafana's own OIDC. It was removed; §10 is the measured reason and it is worth reading before
re-adding anything, because the failure it caused only shows up an hour into a session.

What gates the host now:

1. **OIDC** supplies identity and role: `contains(groups[*], 'titan-grafana-admins') && 'Admin' ||
   'Viewer'`. `GrafanaAdmin` (server admin) is not granted to anyone. With
   `GF_AUTH_GENERIC_OAUTH_AUTO_LOGIN=true` an unauthenticated browser gets a silent 302 to
   `auth.titan.arrieta.eu` rather than a Grafana login form — so from outside it still *looks* like
   the old edge gate, and §7 step 3 still expects a 302. It is now Grafana issuing it, not Traefik.
2. **The group bindings decide who is admitted**, and they answer before Grafana ever sees a token:
   the application is bound to `titan-family` (order 0) or `titan-grafana-admins` (order 1), so
   anyone in neither is refused at the IdP and never reaches Grafana to be made a Viewer. That
   binding is what switched this app off "any authentik user may log in".
3. **TLS only.** The Ingress pins `router.entrypoints: websecure`. Traefik here runs no HTTP→HTTPS
   redirect (`apply/20-infra/traefik/traefik.yaml`, the `ports.web.http.redirections.entryPoint`
   note), so an unpinned Ingress answers on cleartext `:80` — measured before this change, where
   `http://grafana.titan.arrieta.eu/api/health` reached the outpost on port 80. The forwardAuth
   Middleware covered that router as a side effect; the pin is what covers it now, for the same
   reason `llm` and `investing-agent` pin.

**The bindings are the only admission decision — but they were already the deciding layer.** The old
edge gate never consulted *this* application. The outpost has exactly one provider, `forward_domain`
over `titan.arrieta.eu`, and it resolves every host under the domain to the `tesla` application
(`apply/50-apps/auth/tesla-outpost-blueprint.yaml`, "WHY THE UNION OF THREE GROUPS"). So what the
Middleware enforced was tesla's three bindings — `titan-family`, `titan-grafana-admins`,
`titan-tesla-grafana-admins` — which are a superset of this application's two. Removing the edge gate
therefore changed nobody's access: anyone who now reaches Grafana's OIDC was already allowed past the
edge, and anyone in neither of these two groups is refused at the IdP exactly as before. What changed
is that nothing upstream of here catches a mistake any more.

They live in `authentik/blueprints-observability.yaml`, rendered into the sops Secret
`apply/10-secrets/authentik-observability-blueprint.yaml`, not in the Grafana manifest.
`make observability-oidc-check` fails when the reviewed blueprint carries no `policybinding` for this
application, when its group set is not exactly `titan-family` + `titan-grafana-admins`, or when
`policy_engine_mode` is anything other than `any` — and that same gate already fails when the rendered
artifact drifts from the template, which is what carries the proof to the applied copy. To read the
applied rows directly rather than trust the gate:

```sh
sops -d apply/10-secrets/authentik-observability-blueprint.yaml \
  | grep -A6 "policybinding" | grep -E "target|group|order"
```

Two `policybinding` rows naming `titan-family` and `titan-grafana-admins` is the expected answer. If
either is gone, this host is open to every authentik account as `Viewer`.

The `profile` scope is load-bearing on **both** sides of the pair — the `groups` claim exists only
because authentik's default profile-scope mapping emits it. Drop it on either side and every login
silently lands as `Viewer`: a permissions bug that presents as working.

`GF_AUTH_BASIC_ENABLED` stays `true` on purpose. If the OIDC config is ever wrong (rotated secret,
wrong JWKS, dropped scope) and basic auth were off, the only way back in would be editing the Secret
and restarting the pod. The local admin is how you fix Grafana when the identity provider is the
thing that is broken.

## 5. Dashboards are edited in git, not in the browser

Every provider sets `allowUiUpdates: false`. casa's provisioning uses `editable: true`, which lets a
browser edit survive every later apply invisibly — the same class of live drift `AGENTS.md` warns
about for `kubectl edit`, and `make dry-run` cannot see it.

To add a dashboard:

1. Drop a ConfigMap under `apply/50-apps/grafana/grafana-dashboards/` in namespace `observability`,
   with the JSON under a single `.json` key.
2. Add a provider entry to `grafana-dashboard-provisioning.yaml` pointing at the directory it mounts
   into, with `allowUiUpdates: false`.
3. Add a `volume` + `volumeMount` pair on the Deployment in `grafana.yaml`.
4. **List the file in `apply/50-apps/kustomization.yaml`.** An unlisted manifest builds green and is
   silently never applied — `make kustomize-listing` is the gate that exists for exactly that.

Copied dashboard files are left **unedited** apart from the one anchored `namespace:` line, so a single
`cmp` against `k8s-casa` proves a re-sync changed nothing else. That is deliberate and it has a cost:
some copied headers name casa's own paths — `security-scans-dashboard.yaml` and `alerts-dashboard.yaml`
say they are mounted in `apply/50-apps/casa/grafana.yaml`, which is true there and false here. Fixing
those two comments is free to type and not free to verify, so they stay. The mount is the
`volumeMounts` list in `apply/50-apps/grafana/grafana.yaml`, which is the only thing here that decides
where a dashboard actually lands.

**The one deliberate exception is `amdgpu-dashboard.yaml`.** Since 2026-10-29 it is edited, which breaks
the "copied verbatim" rule, and the break is recorded as **D7** in
`docs/superpowers/specs/2026-10-21-titan-grafana-design.md`. The two new panels — `Requests deferred
/ processing` and `KV cache tokens` — were asked for on the titan-side board and resolve on the same
shared Prometheus the rest of the board reads (via the `casa-halogen` ScrapeConfig). The divergence is
titan-side only: casa's own copy is untouched. The rule's premise — that a copied file is an unmodified
copy — no longer holds for this one, so the single-`cmp` re-sync proof no longer applies to it.

## 6. When a dashboard edit does not appear

Check this **first**, because it looks like Grafana ignoring its own config:

`reloader.stakater.com/auto: "true"` on the Deployment is **inert** unless `observability` appears in
`values.reloader.namespaces` in `apply/20-infra/reloader/reloader.yaml`. Reloader does not look at a
namespace outside that list. This has now bitten three times — promtail, then open-webui, then here —
and each time the pod reported healthy while serving whatever it read at start.

```sh
kubectl -n apps get helmrelease reloader -o jsonpath='{.spec.values.reloader.namespaces}'; echo
kubectl -n observability get pod -l app=grafana -o jsonpath='{.items[0].status.startTime}'; echo
kubectl -n observability get cm grafana-node-exporter-dashboard -o jsonpath='{.metadata.creationTimestamp}'; echo
```

If the ConfigMap is newer than the pod and no rollout happened, the namespace is missing from that
list. The same rule applies to the OIDC Secrets: a rotated client sits unread until something
restarts the pod.

### The definitive check is Reloader's own annotation, not the pod's age

Pod start time only tells you something restarted. This tells you Reloader did, and which ConfigMap it
blames:

```sh
kubectl -n observability get deploy grafana -o jsonpath='{.spec.template.metadata.annotations.reloader\.stakater\.com/last-reloaded-from}'; echo
```

Measured on 2026-10-21, after a one-comment change to `grafana-datasources`:

```json
{"type":"CONFIGMAP","name":"grafana-datasources","namespace":"observability",
 "hash":"e6521c2f0f06d816da77cb73575f5734e15353b3","containerRefs":["grafana"]}
```

**Do not look for `reloader.stakater.com/configmap-checksum`.** Older Reloader wrote that on the pod;
this version does not, and a runbook that told you to grep for it produces a confident false negative on
a deploy where the restart demonstrably happened — which is exactly what happened when this section was
first written from assumption rather than measurement.

Two timings worth expecting, both measured:

- **Merge to applied is not immediate.** The stage cascade runs one cycle behind, so `apps` sat on
  `dependency 'flux-system/certificates' is not ready` for roughly four minutes before it picked the
  commit up. Nothing is stuck; the `Kustomization` conditions resolve one second out of order and
  self-heal on the next pass.
- **The outage is about 12 seconds, not zero.** `strategy: Recreate` is deliberate — the PVC is RWO, so
  a rolling update would leave the new pod Pending on a volume conflict forever. Expect a gap with no
  ready pod rather than an overlap.

## 7. Verification

Run in order; each step distinguishes "not deployed" from "deployed and wrong".

```sh
# 1. workload up, volume bound
kubectl -n observability get pvc,deploy,pods -l app=grafana

# 2. Grafana itself is healthy — inside the cluster, so this bypasses the public edge entirely
kubectl -n observability exec deploy/grafana -- wget -qO- localhost:3000/api/health

# 3. Expect 302 to auth.titan.arrieta.eu. A 200 here means Grafana's OIDC is not engaging: the page
#    is still behind Grafana's own login (anonymous org and signup are both off), but SSO is not
#    wired. Since 2026-11-05 this 302 comes from GRAFANA, not from a Traefik forwardAuth Middleware
#    (§4, §10) — it proves SSO is wired, it no longer proves a proxy gate.
#    WHO ISSUED THE 302 is readable off the Location: `redirect_uri=...%2Flogin%2Fgeneric_oauth` is
#    Grafana (correct now); `redirect_uri=...%2Foutpost.goauthentik.io%2Fcallback` means an outpost
#    is in front of this host again.
curl -sSI https://grafana.titan.arrieta.eu/ | head -5

# 3b. cleartext must NOT answer. The Ingress pins router.entrypoints: websecure, so port 80 has no
#     router for this host: expect a 404 from Traefik, not a 302 and not a Grafana page.
curl -sS -o /dev/null -w '%{http_code}\n' http://grafana.titan.arrieta.eu/

# 4. TLS is the wildcard, not Traefik's default cert (default cert = Reflector has not delivered)
echo | openssl s_client -connect grafana.titan.arrieta.eu:443 -servername grafana.titan.arrieta.eu \
  2>/dev/null | openssl x509 -noout -subject -dates

# 5. datasources answer from outside the cluster too
curl -sS -G https://prometheus.local.arrieta.eu/api/v1/query --data-urlencode 'query=count(up)'

# 6. BEFORE signing in: did authentik actually ingest the blueprint? Mounting is not applying, and
#    this repo has a dated record of a mounted blueprint that silently never applied (see below).
#    Needs an admin context — k8s-reader is Forbidden on pods/exec in `auth`.
kubectl -n auth exec deploy/authentik-worker -- ak shell -c 'for b in __import__("authentik.blueprints.models", fromlist=["BlueprintInstance"]).BlueprintInstance.objects.all(): print(b.name, b.path, b.status, b.last_applied)'
> Written as one expression with no `;` on purpose. A semicolon-separated `-c` string does not survive
> pasting into a shell reliably — measured 2026-10-21, where `from x import y; print(...)` arrived at
> Django as just `from x import y` and failed with a SyntaxError that looked like a broken query.

```

**A `titan-observability` row must exist before you debug a login.** Its absence is not a lag and not a
Grafana bug: `docs/authentik-runbook.md` §5 records 2026-10-20, when `authentik-grafana-blueprint` was
applied by Flux, the worker restarted for it, the file was demonstrably on disk at 5637 bytes, and
`apply_blueprint` finished with `exc: null` — and **no `BlueprintInstance` was created**. Nothing
reported a failure; the blueprint list simply did not contain it, and it cost an hour of live breakage.
The `path` column settles what no log answers: mounted blueprints land at
`mounted/secret-<secret>/<key>.yaml`, so it distinguishes a wrong mount from a wrong blueprint.

Then in the browser: sign in through authentik and **check the role, not just the login** (an
authentik Admin must land as `Admin`); Connections → data sources → Save & test on both; and one
panel per dashboard, with §3 telling you which empties are expected.

Finally, prove the drift controls work — and be precise about what the first one proves, because
"the UI let me save a dashboard" is not automatically a failure:

- **Overwriting a provisioned dashboard must be refused.** `allowUiUpdates: false` is set on all seven
  providers, and it blocks saving *over the file-backed UID*. The original board should still show the
  **Provisioned** badge and refuse a plain Save.
- **"Save As" is allowed, and that is correct.** It creates a new dashboard with a new UID that no
  provider owns, so nothing is being overwritten. Measured on first deploy: saving a copy of
  `Security Scans` as `Security Scans 2` succeeded, and that is expected behaviour, not a hole.

The consequence of a Save As copy is worth knowing: it lives in Grafana's sqlite on the PVC — the one
part of this deployment with no backup — and git can never change or delete it. Delete copies you do not
want, or keep them knowingly.

The second control is the one that actually fails silently: change one byte of a dashboard in git, push,
and confirm the pod restarts. Confirm it with Reloader's annotation from §6 rather than the pod's age —
"a new pod" and "Reloader did it" are different claims. This was measured working on 2026-10-21 (§9), so
a failure here is a regression, not an unknown.

### Forcing the blueprint

The worker discovers mounted blueprints at startup and hourly. To apply now rather than wait, use the
authentik UI or the same code path the periodic task uses:

```fish
kubectl -n auth exec deploy/authentik-worker -- ak apply_blueprint \
  /blueprints/mounted/secret-authentik-observability-blueprint/observability.yaml 2>&1 \
  | sed -E 's/[a-f0-9]{64}/REDACTED/g' | tail -5
```

Two cautions, both from `docs/authentik-runbook.md` §5, and both traps rather than background:

- that `exec` needs an **admin context** — the read-only `k8s-reader` identity is `Forbidden` on
  `pods/exec` in `auth`;
- **a blueprint validation failure prints the client secret to stdout.** The `sed` above is not
  decoration: the generated `client_secret` is 64 hex characters, which is exactly what that filter
  catches. Do not paste the output anywhere until it has been read.

If the run reports success but step 6 still shows no row, that is the 2026-10-20 failure and the fix
was a second worker restart: `kubectl -n auth rollout restart deploy/authentik-worker`.

## 8. Not proven

- **The PVC is deliberately outside the backup stage and no restore has ever been drilled.**
  `apply/70-backup/` backs up whatever carries `backup.titan.arrieta.eu/class`, and this PVC does
  not carry it: every provider here sets `allowUiUpdates: false`, the datasources are a ConfigMap,
  and the admin credentials are in `observability-grafana-admin.yaml`, so a wiped volume rebuilds
  itself and costs only what someone built by hand in the UI. That is the argument for the
  exclusion, and it is still only an argument — nobody has wiped the volume to find out what else
  was in the sqlite file.
- **The §10 fix has never been observed working.** The middleware removal is a commit and a green gate
  run, not a measured hour of open dashboards. Until someone leaves a board open past ~10 minutes and
  sees `/api/ds/query` answer 200 the whole time, the fix is a well-evidenced diagnosis and a
  plausible repair, not a verified one (§10).
- **Nothing proves the two group bindings on the live authentik.** `make observability-oidc-check`
  proves the reviewed blueprint carries them and that the rendered artifact equals it, and
  `blueprint-mount-check` proves the blueprint is mounted — but mounting is not applying, and
  §9 is the dated record of a mounted blueprint that silently never applied. The bindings are now the
  only thing admitting anyone (§4), so the applied state is worth checking with §7 step 4b, not just
  the committed one.
- **`make release-secrets` does not scan this Deployment.** It reads `HelmRelease` values only, so a
  typo'd `secretRef` here surfaces as a `Pending` pod, not a red gate. open-webui has the same hole.
- **Blueprint ingestion works, but only after a second restart.** Proven on first deploy (§9): the
  Reloader-triggered restart skipped the file and a manual restart ingested it. The `BlueprintInstance`
  row from §7 step 4b is the only thing that distinguishes "never ingested" from "ingested and fine",
  and mounting in both places is necessary but not sufficient.
- **No alerting.** No rules, no contact points, no Alertmanager here. The `alerts` board shows
  casa's.
- **`grafana.titan.arrieta.eu` has no explicit DNS record** and relies on the `*.titan` wildcard.
  That holds until something issues a `*.grafana.titan` certificate — which is what forced explicit
  A records for `coder.titan` and `streaming.titan`. If this host ever starts failing to resolve
  while the Certificate reports Ready, that is the mechanism.

## 9. First deploy — measured 2026-10-21

Merged as `9e48f0c` at 14:59:06Z. Everything below was run from a workspace with the read-only
`k8s-reader` identity; nothing here is a claim about a command that was not run.

> **Read this through §10.** Several observations below are artifacts of the forwardAuth Middleware
> that was removed on 2026-11-05 — the `set-cookie: authentik_proxy_…` header and the sentence "the
> forward-auth annotation landed" describe a state that no longer exists on this host. They are kept
> as the record of what was measured, not as a checklist.

**Converged.** All seven `Kustomization`s `Ready=True` at `main@sha1:9e48f0c` by 15:03. The first
reading of the chain was all-red — `secrets: dependency 'flux-system/flux-system' is not ready` — and
that was an artifact, not a fault: `secrets` evaluated its dependency at `14:59:32` and `flux-system`
reported `ReconciliationSucceeded` at `14:59:33`. One second. Worth recording because the red cascade
looks alarming and resolves itself on the next cycle without intervention.

**Workload.** `pvc/grafana-data` `Bound` 1Gi `local-path-retain`; `deploy/grafana` 1/1; pod `Running`,
0 restarts.

**Edge gate holds.** `curl -sSI https://grafana.titan.arrieta.eu/` → `HTTP/2 302`, `location` at
`auth.titan.arrieta.eu/application/o/authorize/` with the redirect state pointing back at
`grafana.titan.arrieta.eu`, and `set-cookie: authentik_proxy_…; Domain=titan.arrieta.eu`. The
forward-auth annotation landed.

**TLS is the wildcard.** Subject `CN=titan.arrieta.eu`, SAN `*.titan.arrieta.eu`, issuer Let's Encrypt
`YR1`, `notAfter Jan 1 13:55:37 2027 GMT`. Not the Traefik default, so Reflector delivered `titan-tls`
into `observability`.

**Prometheus path intact.** `count(up)` → `106`, matching the §2 baseline.

**Loki is under a path prefix, and that is not a defect.** `https://loki.local.arrieta.eu/` answers
`200 OK`, `/api/v1/labels` and `/ready` answer `404`, and `/loki/api/v1/labels` answers `200`. Grafana's
Loki datasource appends `/loki/api/v1/...` to the configured URL itself, so `url:
https://loki.local.arrieta.eu` is correct — confirmed against casa's own datasource, which points at
`http://loki-gateway.monitoring.svc` behind an ingress that routes `/` prefix to the same gateway. The
`/ready` 404 is the gateway not exposing that path, nothing more.

**Both drift controls landed live.** `values.reloader.namespaces` on the live `HelmRelease/reloader` is
`["coder","auth","monitoring","open-webui","observability"]`, and `spec.values.blueprints.secrets` on
the live authentik `HelmRelease` ends with `authentik-observability-blueprint`. Reloader fired for it:
`authentik-worker-7f9c88dc6f-wt5t8` started `2026-10-21T15:02:04Z`, three minutes after the merge.

### Not met: the OIDC provider does not exist yet

`https://auth.titan.arrieta.eu/application/o/observability/.well-known/openid-configuration` → **404**,
probed at 15:03 and twice at 15:05, while the control `/application/o/tesla-boards/…` → **200**. The
`jwks/` path 404s identically. So the blueprint has not been applied, and Grafana's OIDC login cannot
succeed until it is — the edge gate will hand a browser to authentik and authentik will not recognise
the client.

This is the §5 signature exactly, and note how much evidence says the *plumbing* is right: the Secret is
applied, the HelmRelease mounts it, the worker restarted for it. Mounting is necessary and not
sufficient, and the only thing that distinguishes "not yet" from "silently never" is the
`BlueprintInstance` query in §7 step 4b — which needs an admin context, as does `pods/exec` for §7 step
2 (`system:serviceaccount:k8s-reader:k8s-reader cannot create resource "pods/exec"` in `observability`,
recorded rather than assumed).

**Still unverified as of this writing:** the `BlueprintInstance` row, in-cluster `/api/health`, the role
an authentik Admin actually receives, both datasources' Save & test, one panel per dashboard, and the
UI/restart drift controls.

### The blueprint did not land on first deploy — 2026-10-21, and what it cost to diagnose

`ak apply_blueprint` succeeded and the provider is live, but **no `BlueprintInstance` row was created**,
so the provider exists and is unmanaged: nothing in authentik knows it came from git, and nothing will
re-apply it. Same end state as 2026-10-20.

Evidence trail, including the two readings that were wrong, because the wrong turns are the useful part:

1. `…/o/observability/.well-known/openid-configuration` → 404 while `…/o/tesla-boards/…` → 200. That
   pair is a good test and worth keeping: it proves the provider is absent without any admin access.
2. The live `HelmRelease` lists `authentik-observability-blueprint` in `blueprints.secrets`, the live
   Reloader namespaces include `observability`, and `authentik-worker` restarted at `15:02:04Z`. So the
   mount and the restart both happened, and neither was sufficient — again.
3. `ls -l /blueprints/mounted/secret-authentik-observability-blueprint/` printed `total 0`, which was
   read as "the Secret projected nothing". **That reading was wrong**, and the second opinion that
   caught it was cheap: `kubectl get secret … -o go-template` showed the key `observability.yaml`
   present, created `15:00:03Z`, and `ls -la` on the same path minutes later showed
   `observability.yaml -> ..data/observability.yaml` with the `..2026_10_21_15_02_04` projection
   directory. The `total 0` is unexplained and should be treated as bad data, not as a fact.
   **Lesson: `ls -la`, not `ls -l`, and check the Secret's keys before believing an empty listing.**
4. After `ak apply_blueprint`: discovery and jwks both `200`, issuer
   `https://auth.titan.arrieta.eu/application/o/observability/`, and all four endpoints Grafana is
   configured with matched the live discovery document exactly — `authorize`, `token` and `userinfo`
   global, `jwks` carrying the slug, all four scopes offered, `refresh_token` granted. The manifest was
   never the problem.

**Closed on 2026-10-21 at 15:33:53Z.** `kubectl -n auth rollout restart deploy/authentik-worker` fixed
it: startup discovery created the row —

```
titan-observability mounted/secret-authentik-observability-blueprint/observability.yaml successful 2026-10-21 15:33:53
```

— 13 seconds after the new pod started, alongside the four blueprints that had been there all along.

The uncomfortable part is *which* restart worked. Reloader restarted the worker at 15:02:04 when the
Secret landed, the projection directory carries that same `15:02:04` timestamp, and discovery still
skipped the file. A manual restart half an hour later, with the identical mount, ingested it
immediately. The difference between the two is not explained by anything measured here, and the
2026-10-20 incident needed the same second restart — so treat the pattern, not the cause:

> **After adding a blueprint Secret, the Reloader-triggered restart is not enough. Check the
> `BlueprintInstance` row (§7 step 4b). If it is absent, restart the worker once more and check again.**

What a missing row actually costs is worth stating, because it is not downtime: `ak apply_blueprint`
creates the objects and they survive restarts, so logins work — which is exactly why this is easy to
leave half-fixed. Without the row nothing reconciles the provider, so a later edit to the blueprint in
git changes nothing, and the next person has no record that the client came from a blueprint at all.

### Browser verification — 2026-10-21, by the operator

Signed in through authentik, checked the role rather than just the login, ran Save & test on both
datasources, and looked at the boards. Reported good on all of it. The one observation worth recording
is the `Save As` case above: a copy of `Security Scans` saved as `Security Scans 2`, which is permitted
by design and is not `allowUiUpdates` failing — all seven providers carry `allowUiUpdates: false`, and
what that flag blocks is overwriting the file-backed UID.

Recorded at that granularity on purpose. Per-panel values were not captured, and the expected empties
(`postgres` is casa's database, `alerts` is casa's Alertmanager, `security-scans` is thin by
construction) were not individually re-listed against what appeared.

**The git half of the drift control is now proven, not assumed.** A single comment line added inside
the `prometheus.yaml` value of `ConfigMap/grafana-datasources` — inside the block scalar, so it changes
the stored string and therefore the checksum, while changing no behaviour — produced, on merge:

```
live ConfigMap before   212 bytes  sha256 b85d685f85911a97
after merge             467 bytes  sha256 1658ef6f809c0a8e   (byte-identical to the built manifest)
pod                     grafana-5cc9bcb89b-qbcqz (15:02:03) → grafana-77dc46f445-27zdz (16:04:28)
Deployment              generation 2, revision 1 → 2, old ReplicaSet scaled to 0
Available again         16:04:40Z
Reloader's own record   last-reloaded-from names grafana-datasources, hash e6521c2f…, containerRefs [grafana]
```

The causal chain is documented rather than inferred, which matters because every claim in §5 about
editing dashboards in git depends on it. Note where the comment had to go: a YAML comment above `data:`
is discarded at build time, produces identical stored bytes, and would have shown no restart for a
reason that had nothing to do with Reloader.

## 10. Panels go "No data" after a while — measured 2026-11-05, and the fix

**Symptom.** A dashboard loads and shows live data. After some minutes the panels stop refreshing and
read "No data". Reloading the whole page brings the data back for another while. Nothing on the pod
looked wrong throughout: 0 restarts in 6d20h, and **zero `level=error` or `level=warn` lines in 72
hours of logs.**

**Root cause: the proxy-side gate, not Grafana.** Traefik's own access log is the only place that
sees every panel poll, and it shows the failure outright:

```
13:18:45 POST /api/ds/query?ds_type=prometheus&requestId=SQR132  302  size=0
13:18:45 POST /api/ds/query?ds_type=prometheus&requestId=SQR133  302  size=0
   ... 16 x /api/ds/query 302, plus /api/annotations and the label-value calls
13:18:48 GET  /d/amdgpu/amd-gpu-2b-system?...&refresh=30s        302
13:18:49 GET  /user/auth-tokens/rotate?redirectTo=/d/amdgpu...   302
13:18:49 GET  /d/amdgpu/amd-gpu-2b-system?...&refresh=30s        200   <- fixed
```

The discriminator that put this on Traefik and not on Grafana: **Grafana's log is empty from 13:18:45
to 13:18:47.** Those sixteen query requests were answered by the `forwardAuth` Middleware and never
reached the pod. The chain:

1. The dashboard polls `/api/ds/query` every 30s (`refresh=30s` is right there in the URL).
2. authentik refreshes its proxy cookie **only when a browser follows a top-level navigation through
   the outpost**. A dashboard does not navigate — it polls by XHR, and an XHR cannot complete a
   cross-origin redirect to mint a cookie.
3. When the cookie aged out (measured gaps before a 302 burst: 588s, 364s, 987s), Traefik answered
   **every** request with a 302 to `auth.titan.arrieta.eu`.
4. The browser follows that redirect on an XHR, the panel receives HTML instead of JSON, and it
   renders "No data" while the page itself still looks perfectly healthy.
5. A full page reload *is* a top-level navigation, so authentik silently re-issues the cookie and the
   data returns. **That is why a reload fixed it and why nothing server-side ever looked broken.**

**Why casa's Grafana never had this.** It has no middleware at all — its Ingress annotations are `{}`.
Its polls never pass through authentik, so they can never be 302'd. That comparison is what localised
this in one step; the two instances differ on image, datasource path and edge gate, and only the gate
produces a 302 on an XHR.

**Two readings that were wrong, recorded because both looked like findings.**

- *"`/api/live/ws` dies 6–92 ms after connecting — a websocket flap!"* Artifact. casa's **working**
  Grafana logs the identical `status=-1 time_ms=6`. For a hijacked connection Grafana records the
  hijack duration, not the connection lifetime.
- *"No `/api/ds/query` in Grafana's log — the queries are being blocked!"* Also an artifact. casa logs
  zero too; Grafana simply does not log that path at info. The place to look was Traefik.

Also ruled out with evidence: the mesh datasource path (73 ms, `count(up)` → 107), pod health, and
`token needs to be rotated` 401s — present on both instances, and casa has **more** of them (21 vs 1),
so it is normal Grafana cookie rotation and not the fault.

**The fix.** Remove the `forwardAuth` Middleware and its `router.middlewares` annotation, and let
Grafana's own authentik OIDC be the gate — §4. Tuning the cookie lifetime was the other candidate and
was rejected: an XHR can never refresh that cookie no matter how long it lives, so a longer lifetime
only moves the timer. This is the shape coder, open-webui, mealie and opencloud already run, and
`NOT_PROXY_GATED` in `tools/ingress-auth-check.py` now carries the reason so the omission cannot be
silently reverted.

**What it costs — and what it does not.** Nothing upstream of Grafana's own OIDC decides anything here
any more. That sounds like a widening and it is not one: the outpost resolved this host to the **tesla**
application, not the `observability` one, because its single `forward_domain` provider matches every
host under `titan.arrieta.eu` (`apply/50-apps/auth/tesla-outpost-blueprint.yaml` says so in its own
words). The edge was therefore enforcing tesla's three groups, a superset of the two that gate this
application, so the set of people who can reach a panel is unchanged. What is genuinely different is
that a mistake in `authentik/blueprints-observability.yaml` now has nothing in front of it —
`make observability-oidc-check` is the gate that holds that line (§4).

**Was not proven; now observed.** Written as unverified, then checked against the live cluster on
2026-11-05, the day it merged. Traefik's access log for the Grafana router shows `/api/live/ws` answered
`302` continuously from 12:52:25 to **15:21:31**, and `401` from Grafana itself at **15:39:06** — the
outpost stopped being in front between those two, and a `401` from Grafana is the shape of "no proxy, no
session" rather than "proxy refused". After 15:21:31 there is **no 302 at all** on that router for the rest
of the window, while `/api/user/auth-tokens/rotate` returns `200` on a ~10-minute cadence from 14:07
through 15:55 — a sustained authenticated session spanning the cutover and half an hour past it. Cleartext
also closed: `http://grafana.titan.arrieta.eu/api/health` now answers **404**, where the same URL answered
through the outpost before the change.

What that does and does not retire. It retires "the middleware is still in front" and "the websecure pin did
not take". It does **not** retire the original symptom's own test — nobody has watched a single dashboard
panel poll `/api/ds/query` for an hour past the cookie lifetime and logged the absence of a 302 burst. The
`/api/ds/query` calls in that window were `200`, but they sit before the cutover, so they show a fresh
cookie working, which was never the bug.

**If it comes back,** the first thing to check is whether something re-added the middleware annotation
(`kubectl -n observability get ingress grafana -o jsonpath='{.metadata.annotations}'; echo`), and the
second is whether the same 302-on-XHR shape is now hitting another gated host. Two still sit behind
`apps-teslamate-auth@kubernetescrd`:

- `apply/60-tesla/teslamate.yaml` — the TeslaMate UI. Its own login is **Tesla's OAuth, not authentik**,
  so dropping the edge here swaps "a member of these groups" for "anyone with a Tesla account". **Decided
  2026-11-05: the gate stays.** The failure is real and was measured — 26 of 36 `/live/websocket` attempts
  answered 302 over 7 days, in three Phoenix-backoff bursts — and it is accepted as the price of keeping
  group admission on a host with no IdP integration of its own. Remedy is a reload. Full evidence and the
  two rejected alternatives: `docs/teslamate-runbook.md` §9.
- `apply/50-apps/investing-agent/investing-agent.yaml` — the console. It carries its own form login at
  `/login` with a signed session cookie, and its manifest documents "TWO LOGINS, DELIBERATELY". Dropping
  authentik leaves the password login as the only gate — the same call already made for Home Assistant in
  issue #112, and again the operator's call.

`apply/60-tesla/grafana.yaml` — **tesla-boards, also a Grafana, had this exact failure on the same timer
and got the same fix on 2026-11-05.** It is no longer behind the outpost: its own authentik OIDC and the
two bindings on the `tesla-boards` application decide who gets in, and `make grafana-oidc-check` holds
those bindings. So if the 302-on-XHR shape comes back for a *Grafana*, there are now no gated Grafanas
left to look at — check for a re-added annotation on one of the two hosts above instead.

Of the two hosts still behind the outpost, one has now been decided and one has not: teslamate keeps the
gate on purpose (above), and `investing-agent` remains an open operator decision — its own form login at
`/login` would become the only gate, which is the same call already made for Home Assistant in issue #112
and, like that one, not an agent's call to make. Issue #243 records why neither is the same mechanical edit
as this one.
