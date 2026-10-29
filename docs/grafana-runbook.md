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
| Edge gate | authentik forward-auth via `Middleware/observability/grafana-auth` |
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

Two layers, deliberately, and they answer different questions:

1. **The edge gate** decides whether the host may be reached at all. It never tells Grafana who you
   are. Unauthenticated browsers get a 302 to `auth.titan.arrieta.eu`.
2. **OIDC** supplies identity and role: `contains(groups[*], 'titan-grafana-admins') && 'Admin' ||
   'Viewer'`. `GrafanaAdmin` (server admin) is not granted to anyone.

A third layer sits in front of both, inside authentik: the application is bound to `titan-family` or
`titan-grafana-admins` (`authentik/blueprints-observability.yaml`), so anyone in neither is refused at
the IdP before a token exists and never reaches Grafana to be made a Viewer. That binding is what
switched this app off "any authentik user may log in".

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

# 2. Grafana itself is healthy — inside the cluster, so this does not cross the edge gate
kubectl -n observability exec deploy/grafana -- wget -qO- localhost:3000/api/health

# 3. THE ONE THAT MATTERS MOST: expect 302 to auth.titan.arrieta.eu.
#    A 200 here means the forward-auth annotation did not land and the homelab's metrics are public.
curl -sSI https://grafana.titan.arrieta.eu/ | head -5

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
- **Grafana's gating is coupled to a Tesla-owned blueprint.** The proxy provider that gates this host
  is `forward_domain` over `titan.arrieta.eu` and lives in
  `apply/50-apps/auth/tesla-outpost-blueprint.yaml`. Narrowing it later silently locks the homelab's
  dashboards.
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
