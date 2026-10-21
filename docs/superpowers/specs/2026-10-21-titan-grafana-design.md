# titan — Grafana, reading casa's Prometheus, with the casa dashboards

Status: **accepted design, not yet implemented**. The implementation plan is a separate document;
this one decides the shape and records what was measured rather than assumed.

Written 2026-10-21. The request was "a Grafana deployment, the same dashboards as the one in
`../k8s-casa`, connecting to `https://prometheus.local.arrieta.eu`". Two things in that request did
not survive contact with the tree. The first is that **titan already has a Grafana** —
`apply/60-tesla/grafana.yaml`, `tesla-boards.titan.arrieta.eu`, whose own header says the host was
renamed off `grafana.` *"because a second Grafana is coming"*. So this is the second one that was
already planned, not an unexpected duplicate. The second is that the datasource named in the request
is a **shared** Prometheus holding three clusters, which turns "same dashboards" from a copy job into
a decision about what this instance is *for*. Six decisions were put to the operator one at a time;
each is recorded below with the alternative that was declined.

## 1. What this is for

A Grafana on titan that is the homelab's pane of glass, not titan's dashboard. It reads casa's
Prometheus and casa's Loki over the WireGuard mesh and shows everything they hold — casa, titan and
techdelivery — with no cluster filtering. The operator's stated intent is to retire casa's Grafana or
reduce it to LAN-only, so this instance inherits the role rather than competing with it.

Success looks like: `https://grafana.titan.arrieta.eu` answers, refuses an unauthenticated browser to
authentik, signs in with no local password form, shows the seven casa dashboards with panels that
contain data, and is changed only through git — a dashboard edit that happens in the UI is an
anomaly this design tries to make impossible rather than something to notice later.

## 2. What was measured

Everything below was read from the live Prometheus, live DNS, the pinned image's registry manifest,
or this repository. Nothing here is a guess carried forward.

| | |
|---|---|
| `https://prometheus.local.arrieta.eu` from a titan workspace | `/-/ready` → **200**; `GET /api/v1/query?query=count(up)` → `106` with **no authentication**. Grafana proxies server-side, so no browser session is involved. This is casa's *internal* Traefik host; the authentik-gated one is `prometheus.home.arrieta.eu` (`k8s-casa/apply/50-apps/monitoring/prometheus.yaml`) |
| What that Prometheus holds | `count by (cluster) (up)` → **94 targets with no `cluster` label** (casa's own), **7 with `cluster="titan"`**, **5 with `cluster="techdelivery"`**. `/api/v1/label/cluster/values` → `["techdelivery","titan"]` |
| titan's own host is in it | `node_uname_info` includes `192.168.133.1:9100` (titan's `wg0`), `node_filesystem_avail_bytes{instance="192.168.133.1:9100"}` → 9 filesystems, `comin_build_info` includes `192.168.133.1:4243`. **The node and comin scrapes carry no `cluster` label** even for titan, while the k8s scrapes do — so `cluster` is not a reliable filter, which is a second reason D1 declines to add one |
| The casa dashboards' datasource binding | every panel of all seven resolves through a **template variable**, not a pinned uid: `node-exporter` 124 panels on `${datasource}`, `postgres` 46 on `$datasource`, `comin` 19, `disk` 11, `alerts` 42, `amdgpu` 42, `security-scans` 8 on `$datasource` plus 14 on `$loki`. Each dashboard declares `datasource` as `type: datasource, query: prometheus` (and `loki` likewise). **This is what makes a byte-for-byte copy work**; a pinned uid would have needed the datasource provisioned under that uid |
| `https://loki.local.arrieta.eu` from titan | `GET /loki/api/v1/query_range?query={cluster="titan"}` → **200** with live authentik pod lines. (`/ready` on that host answers 404 — the path is not served there, which is not an unhealthy Loki; `docs/titan-logs-loki.md` §"Why the push URL is what it is" records the same host resolving to RFC1918 `192.168.0.42`) |
| `grafana.titan.arrieta.eu` DNS | resolves **today** to `<OVH_PUBLIC_IP>` via the `*.titan` wildcard in `../public-dns-tf`. A deliberately nonsense name under `.titan` resolves identically, which is the proof the answer is the wildcard and not a record |
| …and when that stops being true | `coder.titan` and `streaming.titan` each need an explicit A record because cert-manager leaves an `_acme-challenge` node under them, and a wildcard does not apply where a node exists. `grafana.titan` has no such node **as long as nothing ever issues `*.grafana.titan`** |
| `titan-tls` | `apply/40-certificates/titan-wildcard.yaml` already carries `*.titan.arrieta.eu`, so no new `Certificate` is needed — only a Reflector allow-list entry |
| `grafana/grafana:12.3.1` | manifest-list digest `sha256:2175aaa91c96733d86d31cf270d5310b278654b03f5718c59de12a865380a31f`, read from `registry-1.docker.io/v2/grafana/grafana/manifests/12.3.1` with `Accept: …manifest.list.v2+json` |
| The Tesla Grafana's OIDC chain | template `authentik/blueprints-grafana.yaml` → Secret `authentik-grafana-blueprint` (key `grafana.yaml`) → client Secret `tesla-grafana-oidc` (keys `GF_AUTH_GENERIC_OAUTH_CLIENT_ID`, `GF_AUTH_GENERIC_OAUTH_CLIENT_SECRET`) → gate `tools/grafana-oidc-check.py`, which hardcodes `HOST = "tesla-boards.titan.arrieta.eu"` and that redirect. Its authentik application slug is `tesla-boards`, so the slug `grafana` and the word `observability` are both free |
| The escape-hatch Secret shape | `tesla-grafana-admin` carries exactly `GF_SECURITY_ADMIN_USER`, `GF_SECURITY_ADMIN_PASSWORD` |
| Forward-auth plumbing | `apply/60-tesla/teslamate.yaml` defines `Middleware/apps-teslamate-auth` with `address: http://authentik-server.auth.svc.cluster.local/outpost.goauthentik.io/auth/traefik`, `trustForwardHeader: true`, `maxResponseBodySize: 4194304`. Traefik CRD middlewares are **namespaced** — the tesla Ingress references `apps-teslamate-auth@kubernetescrd` from `apps` — so a second namespace needs its own `Middleware` object |
| Reloader is scoped, not global | `apply/20-infra/reloader/reloader.yaml` sets `values.reloader.namespaces` to an explicit list (`coder`, `auth`, `monitoring`, `open-webui`) with `watchGlobally: false`. The comments record that the `monitoring` and `open-webui` entries were added because `reloader.stakater.com/auto: "true"` is **inert** outside that list |
| Blueprint mounting | `apply/50-apps/auth/authentik.yaml` lists blueprint Secrets twice: in the HelmRelease `blueprints.secrets` mount list, and in the `secret.reloader.stakater.com/reload` annotation, because the worker re-discovers blueprints hourly |
| `release-secrets` scope | the Makefile gate scans `HelmRelease` `spec.values…envFrom[].secretRef.name` only. A `Deployment` `envFrom` is **not** covered — the same pre-existing gap as open-webui |

## 3. Decisions

| # | decision | declined alternative, and why it matters |
|---|---|---|
| D1 | **Whole-homelab view.** Dashboards copied verbatim, no `cluster` filter, no new template variable | titan's Grafana then shows casa's 15 node_exporter instances, casa's Alertmanager and casa's scan jobs as well as titan's. Declined: adding a `cluster` variable to a 15.5k-line node-exporter board, and the measurement above shows `cluster` is missing on exactly the node and comin scrapes it would most need to filter. The operator's own framing — casa's Grafana retires or goes LAN-only — makes overlap the temporary state, not the design |
| D2 | **Host `grafana.titan.arrieta.eu`.** No DNS change, no new `Certificate` | Declined: taking over `grafana.home.arrieta.eu`, which is the public name in use today. It would need an explicit `grafana.home` A record overriding the `*.home` CNAME to `dynhome.arrieta.nom.es`, a new `Certificate` in titan, and it drags casa's retirement into the same change — two things that can fail at once, neither provable by `make check`. Also declined: `grafana.local.arrieta.eu`, which is casa's private record (`192.168.0.42`) and is the LAN-only half the operator intends to keep |
| D3 | **Forward-auth at the edge *and* authentik OIDC for identity** — the tesla-boards posture | Declined: forward-auth alone, which leaves a shared admin account as the only thing inside a public host — the exact state `apply/60-tesla/grafana.yaml` records as the reason OIDC was added there. Also declined: OIDC alone, which makes Grafana's own config the only barrier between the internet and every cluster's metrics, and this repo has already had this class of host left ungated by accident |
| D4 | **`apply/50-apps/grafana/`, shared `apps` stage, own namespace `observability`** | Declined: a new `70-observability` stage, which is what §3.2 of the scale-out spec reads as when read literally. The tree already declined that for open-webui (D6 there) and for coder. The spec text conflates "own namespace" with "own stage"; that is a defect in the spec, not in this decision, and is amended in `2026-10-19-titan-app-scale-out-design.md` §3.1/§3.2 as its own commit |
| D5 | **Official `grafana/grafana`, pinned by digest** | `teslamate/grafana` — what both casa and tesla-boards use — ships Tesla's dashboards and provisions a Postgres datasource from `DATABASE_*`. Neither is wanted here, and inheriting the image would inherit both |
| D6 | **`allowUiUpdates: false` on every dashboard provider** | casa provisions with `editable: true`, which lets a browser edit silently diverge from git and survive every later apply. This repo already has a written rule about live drift being invisible to `make dry-run`; git is the only editor of a dashboard here |

## 4. Layout

```
apply/50-apps/grafana/
  grafana.yaml                        PVC + ConfigMap grafana-env + Deployment + Service
                                      + Middleware + Ingress        (namespace observability)
  grafana-datasources.yaml            ConfigMap: prometheus.yaml, loki.yaml
  grafana-dashboard-provisioning.yaml ConfigMap: one provider file per dashboard
  grafana-dashboards/
    node-exporter-dashboard.yaml      copied byte-for-byte from casa except metadata.namespace
    postgres-dashboard.yaml
    comin-dashboard.yaml
    disk-dashboard.yaml
    alerts-dashboard.yaml
    amdgpu-dashboard.yaml
    security-scans-dashboard.yaml
```

No `kustomization.yaml` in that directory — a subdirectory of a stage never gets one. Every file above
is listed in `apply/50-apps/kustomization.yaml`, which is what `make kustomize-listing` enforces;
`coder-db.yaml` is the precedent for what an unlisted manifest costs.

Edits in other people's files, each of which fails silently if missed:

| file | edit | what happens if skipped |
|---|---|---|
| `apply/00-bootstrap/namespaces.yaml` | declare `observability` | every object lands in a namespace Flux did not create; the `Kustomization` fails on the first apply rather than silently, which is the least dangerous of these |
| `apply/40-certificates/titan-wildcard.yaml` | add `observability` to `reflector.v1.k8s.emberstack.com/reflection-allowed-namespaces` **and** `…-auto-namespaces` | Ingress references a `titan-tls` that never arrives; Traefik serves its default cert and the host looks up with a name mismatch. Hand-copying the Secret is forbidden by `AGENTS.md` |
| `apply/20-infra/reloader/reloader.yaml` | add `observability` to `values.reloader.namespaces` | the `reloader.stakater.com/auto: "true"` annotation is **inert** and a dashboard or OIDC Secret edit never restarts the pod — the recorded `monitoring`/`open-webui` defect, restated because it will be hit again |
| `apply/50-apps/auth/authentik.yaml` | add `authentik-observability-blueprint` to `blueprints.secrets` **and** to `secret.reloader.stakater.com/reload` | a valid blueprint that is never mounted is indistinguishable from one never written; this is the failure `grafana-oidc-check` was written for |
| `apply/10-secrets/kustomization.yaml` | list the three new Secrets | `make secrets-placement` fails — that one is loud |

## 5. Datasources

`ConfigMap/grafana-datasources`, mounted at `/etc/grafana/provisioning/datasources`:

- **Prometheus** — `url: https://prometheus.local.arrieta.eu`, `access: proxy`, `isDefault: true`,
  `jsonData.timeInterval: 30s`. No auth: measured unauthenticated above. If casa ever puts that host
  behind authentik, Grafana's server-side proxy has no session to present and every panel goes empty
  at once — that is the dependency to remember, and it is why the datasource test in §11 is a query
  and not a green tick in the UI.
- **Loki** — `url: https://loki.local.arrieta.eu`, `uid: loki`, `maxLines: 2000`. Needed only by the
  security-scans board. The `uid` is pinned for the same reason casa pins it: a hand-made Loki
  datasource in the UI would otherwise make the board's picker a coin flip.

casa's Prometheus datasource carries an `exemplarTraceIdDestinations` block naming a `tempo`
datasource that does not exist here. It is dropped rather than copied.

## 6. Dashboards

Seven ConfigMaps, copied from `k8s-casa/apply/50-apps/casa/grafana-dashboards/` with **only
`metadata.namespace` changed** — `casa` → `observability`. Names keep casa's
`grafana-<topic>-dashboard` shape so a diff between the two trees stays readable.

The provisioning ConfigMap declares one provider per dashboard, `type: file`, folders `Servers` /
`Databases` / `Monitoring` / `Security` as casa has them, `disableDeletion: false`, and
`allowUiUpdates: false` per D6.

What each board shows, given D1, so nobody mistakes an empty panel for a broken one:

| board | reads | on this datasource |
|---|---|---|
| node-exporter | `node_*` | all 17 exporters in the homelab, titan among them; `instance` is a query variable listing them |
| disk | `node_filesystem_*` | same, 9 filesystems on titan |
| comin | `comin_*` | 13 devices including `192.168.133.1:4243` |
| postgres | `pg_*` filtered on `service="postgres-exporter"` | casa's exporter. **titan's CNPG databases are not here** — CNPG's own exporter is not scraped into this Prometheus, so this board is casa's database and nothing else |
| amdgpu | `node_drm_*` | whatever has a GPU; the metric family exists with one series |
| alerts | `alertmanager_*` | casa's Alertmanager. titan runs none |
| security-scans | `kube_job_status_*` (Prometheus) + log lines (Loki) | casa's scan jobs. titan's pod logs are in the same Loki under `cluster="titan"`, but no titan job runs these scans |

## 7. Auth

Two separate questions, kept separate for the reason tesla-boards records: the edge proxy decides
whether the host may be reached at all and never tells Grafana *who* you are; OIDC supplies identity
and role and survives the edge gate being misconfigured.

### 7.1 Edge gate

`Middleware/grafana-auth` in namespace `observability` — its own object, because Traefik CRD
middlewares are namespaced and `apps-teslamate-auth` cannot be referenced from here. Three values
copied from the tesla one and for its documented reasons: the embedded outpost address
(`authentik-server.auth.svc.cluster.local`, Service 80→9000), `trustForwardHeader: true` (the
outpost selects the provider from `X-Forwarded-Host`), and `maxResponseBodySize: 4194304` (what
authentik's own Traefik-3 generator sets; unset, Traefik logs a DoS warning).

The Ingress carries
`traefik.ingress.kubernetes.io/router.middlewares: observability-grafana-auth@kubernetescrd`.
The `@kubernetescrd` suffix is the CRD provider's name, not `@kubernetes`.

**No authentik proxy-provider change is needed.** The provider is `forward_domain` over
`titan.arrieta.eu` with `cookie_domain` at that apex, so any host under the domain is served and the
existing session cookie already covers it. That is also a coupling: the provider lives in
`apply/50-apps/auth/tesla-outpost-blueprint.yaml`, a Tesla file, and a future change there that
narrows it reaches Grafana. Recorded in §10.

### 7.2 OIDC

New template `authentik/blueprints-observability.yaml`, rendered into sops Secret
`authentik-observability-blueprint` under key `observability.yaml`, following
`blueprints-grafana.yaml`'s shape. Application slug `observability`, display name "Grafana",
`client_id`/`client_secret` shared with `observability-grafana-oidc`.

Redirect URI: `https://grafana.titan.arrieta.eu/login/generic_oauth`.

Grafana env, mirroring tesla-boards where the reason is already written down there:

- `GF_AUTH_GENERIC_OAUTH_ENABLED=true`, `…_NAME=authentik`, authorize/token/userinfo at the **global**
  `/application/o/…` paths (only issuer and jwks carry the slug — measured against this instance, per
  the tesla comment), `…_JWK_SET_URL=https://auth.titan.arrieta.eu/application/o/observability/jwks/`,
  `…_VALIDATE_ID_TOKEN=true`.
- `…_SCOPES="openid email profile offline_access"` — `profile` is load-bearing, not decoration: the
  `groups` claim exists only because authentik's default profile-scope mapping emits it.
- `…_ROLE_ATTRIBUTE_PATH="contains(groups[*], 'authentik Admins') && 'Admin' || 'Viewer'"`.
  `GrafanaAdmin` is deliberately not granted.
- `…_ALLOW_SIGN_UP=true`, `…_AUTO_LOGIN=true`, `…_USE_REFRESH_TOKEN=true`.
- `GF_AUTH_BASIC_ENABLED=true` — **the escape hatch**. With basic auth off and the OIDC config wrong,
  the only way back in is editing the admin Secret and restarting the pod.
- `GF_SECURITY_ADMIN_USER`/`_PASSWORD` from `observability-grafana-admin`, which exists because
  Grafana's default admin must not be the way into a public host.
- `GF_SERVER_ROOT_URL=https://grafana.titan.arrieta.eu/`, `GF_AUTH_ANONYMOUS_ENABLED=false`,
  `GF_USERS_ALLOW_SIGN_UP=false` (Grafana's own signup, separate from OIDC's),
  `GF_ANALYTICS_REPORTING_ENABLED=false`, `GF_ANALYTICS_CHECK_FOR_UPDATES=false`, `TZ=UTC`.

Naming, stated so nobody "simplifies" it: the word **grafana** in the existing chain
(`authentik-grafana-blueprint`, `tesla-grafana-oidc`, `blueprints-grafana.yaml`) belongs to **Tesla**,
whose application slug is `tesla-boards`. New objects are named after the namespace to avoid a
collision. Renaming Tesla's chain is a separate change with a working login on the line.

## 8. Workload

- **Image** `grafana/grafana:12.3.1@sha256:2175aaa9…a31f`, digest from §2.
- **Pod security** as tesla-boards: `runAsNonRoot: true`, `runAsUser: 472`, `runAsGroup: 0`,
  `fsGroup: 0`, `seccompProfile: RuntimeDefault`, container `allowPrivilegeEscalation: false`,
  `capabilities.drop: [ALL]`. The official image keeps gid 0 deliberately so a mounted PVC can be
  group-writable.
- **Strategy `Recreate`** — the PVC is `ReadWriteOnce`; a `RollingUpdate` would schedule pod 2 against
  a volume pod 1 still holds and leave it `Pending` on a conflict forever.
- **PVC** 1Gi, `storageClassName: local-path-retain` (open-webui's class, so a `kubectl delete pvc`
  does not eat the volume).
- **Probes** `/api/health` on the http port, liveness `initialDelaySeconds: 30`, readiness same path.
- **Resources** requests 100m/256Mi, limits 500m/512Mi, as tesla-boards.
- **Reloader** `reloader.stakater.com/auto: "true"` on the Deployment, which does nothing until §4's
  `namespaces` edit lands.
- **Ingress** class `traefik`, host `grafana.titan.arrieta.eu`, `secretName: titan-tls` (reflected in).

## 9. Gates

`tools/grafana-oidc-check.py` gains a **variant selector** rather than being forked: its module-level
constants (`TEMPLATE`, `PLACEHOLDERS`, `REDIRECT`, `HOST`, `BLUEPRINT_SECRET`, `BLUEPRINT_KEY`,
`APP_SECRET`, `APP_NS`) become two named configs, `tesla` (current behaviour, unchanged default) and
`observability`. `make grafana-oidc-check` keeps working exactly as now; `make
observability-oidc-check` is added and joins `check`.

A fork was declined because the failure modes are identical — template vs rendered blueprint,
Grafana's copy vs authentik's copy, mounted vs not, redirect host vs served host — and two scripts
drift, which is the thing these gates exist to prevent.

`release-secrets` still will **not** cover this Deployment (§2), so a typo'd `secretRef` here is
caught by the live apply, not by a gate. Closing that gap for Deployments generally is a separate
change; open-webui has the same hole.

## 10. Not proven, and accepted

- **The PVC is not backed up.** This cluster backs up the Postgres cluster and nothing else. With D6
  the volume holds only Grafana's sqlite — users, preferences, API keys — so losing it means
  re-login, not lost dashboards. That is an argument, not a test: no restore of this PVC has been
  drilled.
- **Grafana's gating is coupled to a Tesla-owned blueprint.** The proxy provider that gates this host
  is `tesla-outpost-blueprint.yaml`. Accepted because `forward_domain` needs no change; recorded
  because narrowing it later would silently lock the homelab's dashboards.
- **~25k lines of dashboard ConfigMaps now share the `apps` failure domain.** A malformed one fails
  the Kustomization atomically and freezes coder's and authentik's updates until the next commit.
  Mitigated by `kustomize-check`, `crd-check` and `make dry-run`; §3.2's three-commit promotion to a
  `70-observability` stage stays available if dashboard churn makes the freeze a recurring cost.
- **`cluster` is not a label on everything.** The node and comin scrapes for titan carry none (§2), so
  any future attempt to scope a board by cluster will find the label missing exactly where it is
  wanted.
- **titan's own databases are not on the postgres board.** CNPG's exporter is not scraped into casa's
  Prometheus. D1 does not change that; it is a gap in the metrics pipeline, not in this deployment.
- **No alerting.** No alert rules, no contact points, no Alertmanager here. The `alerts` board reads
  casa's.
- **The `security-scans` board will look thin.** It reads casa's scan jobs, which titan runs none of.

## 11. Verification

Offline, before commit:

    git add -A
    make check          # includes the new observability-oidc-check
    make dry-run DRYRUN_CONTEXT=<admin context>

`dry-run` is the only gate that asks the live API server. The `Middleware` is a
`traefik.io/v1alpha1` object, and `crd-check` does validate its *fields* against
`vendor/traefik-crds` — `Middleware` is already in the checked set from tesla-boards — but a field
that exists in the schema and is wrong for this cluster (a misspelled service, a bad port) is only
visible to the live apply.

Live, after merge, in this order — each step distinguishes "not deployed" from "deployed and wrong":

1. `kubectl -n observability get deploy,pvc,ingress` — pod `Running`, PVC `Bound`.
2. `kubectl -n observability exec deploy/grafana -- wget -qO- localhost:3000/api/health` —
   `database: ok`. Proves Grafana is up without crossing the edge gate.
3. `curl -sSI https://grafana.titan.arrieta.eu/` — expect a **302 to `auth.titan.arrieta.eu`**. A 200
   here means the forward-auth annotation did not land and the host is public. This is the check that
   matters most.
4. Browser: sign in through authentik, confirm the role is Admin for an authentik Admin and Viewer
   otherwise.
5. Connections → data sources: Prometheus **Save & test** returns success. This is the step that fails
   if casa ever puts `prometheus.local` behind authentik.
6. One panel per dashboard returns data, not "No data" — specifically one panel each from
   node-exporter, disk, comin, postgres, amdgpu, alerts, security-scans, and the reason each would be
   empty is in §6.
7. Edit a dashboard in the UI and confirm it is **not** editable (D6), then edit a dashboard in git
   and confirm the pod restarts — proof the Reloader namespace edit landed rather than the annotation
   sitting inert.
