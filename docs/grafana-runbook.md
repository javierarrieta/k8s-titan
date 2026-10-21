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
| amdgpu | `node_drm_*` | whatever has a GPU; the metric family exists with one series |
| alerts | `alertmanager_*` | casa's Alertmanager. titan runs none |
| security-scans | `kube_job_status_*` + Loki log lines | casa's scan jobs. titan's pod logs are in the same Loki under `cluster="titan"`, but no titan job runs these scans, so the Findings rows are thin by construction |

An empty panel on `postgres`, `alerts` or `security-scans` is expected. The point of this table is
knowing which empties are on purpose.

## 4. Login

Two layers, deliberately, and they answer different questions:

1. **The edge gate** decides whether the host may be reached at all. It never tells Grafana who you
   are. Unauthenticated browsers get a 302 to `auth.titan.arrieta.eu`.
2. **OIDC** supplies identity and role: `contains(groups[*], 'authentik Admins') && 'Admin' ||
   'Viewer'`. `GrafanaAdmin` (server admin) is not granted to anyone.

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
```

Then in the browser: sign in through authentik and **check the role, not just the login** (an
authentik Admin must land as `Admin`); Connections → data sources → Save & test on both; and one
panel per dashboard, with §3 telling you which empties are expected.

Finally, prove the drift controls work: the UI should not offer to save a dashboard edit, and a
one-byte change to a dashboard in git should restart the pod. No restart means §6's Reloader list is
missing the namespace.

## 8. Not proven

- **The PVC has no backup and no restore has been drilled.** This cluster backs up the Postgres
  cluster and nothing else. With `allowUiUpdates: false` the volume holds only Grafana's sqlite —
  users, preferences, API keys — so losing it means re-login, not lost dashboards. That is an
  argument, not a test.
- **Grafana's gating is coupled to a Tesla-owned blueprint.** The proxy provider that gates this host
  is `forward_domain` over `titan.arrieta.eu` and lives in
  `apply/50-apps/auth/tesla-outpost-blueprint.yaml`. Narrowing it later silently locks the homelab's
  dashboards.
- **`make release-secrets` does not scan this Deployment.** It reads `HelmRelease` values only, so a
  typo'd `secretRef` here surfaces as a `Pending` pod, not a red gate. open-webui has the same hole.
- **No alerting.** No rules, no contact points, no Alertmanager here. The `alerts` board shows
  casa's.
- **`grafana.titan.arrieta.eu` has no explicit DNS record** and relies on the `*.titan` wildcard.
  That holds until something issues a `*.grafana.titan` certificate — which is what forced explicit
  A records for `coder.titan` and `streaming.titan`. If this host ever starts failing to resolve
  while the Certificate reports Ready, that is the mechanism.
