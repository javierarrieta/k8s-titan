# VPS → titan workload migration — implementation plan

**Date:** 2026-10-30.
**Design:** `docs/superpowers/specs/2026-10-30-vps-to-titan-workload-migration-design.md` — read it
first. This plan is the executable half; the spec holds the decisions (D1–D5), the inventory (§2) and
the constraints (§3–§5). Where this plan restates a measurement it is because the ticket cannot be
executed without it; otherwise it cites the spec or the pre-flight.
**Repos:** `td/` = `k8s-techdelivery` (VPS), `titan/` = `k8s-titan` (destination), `tf/` =
`public-dns-tf`.
**Base:** `titan origin/main@22c5e06`, last-fetched state. Re-verify before the first commit
(spec §9).

## 0. How to work a ticket

Every ticket carries the same five blocks. They are not decoration; three of them are the reason this
plan exists rather than the spec's ticket table.

- **Files:** the exact paths created or edited. A ticket that cannot name its files is not scoped.
- **Copy:** how state moves, if any. `n/a` for stateless.
- **Exit:** one observable command and the output that proves it. Build gates are necessary and not
  sufficient — every gate here is static, and none of them can tell you HA loads.
- **Rollback:** the artifact and the command. For D1 apps rollback is cheap (spec D1 cost column): the
  old name keeps working until the box dies, so revert = point clients back.
- **Gates:** `make check` where the age key and network are available; otherwise `make check-ci`, and
  the PR records which one ran. `dry-run` is **not** in `check` and must be run explicitly.

**Retirement is never in the ticket that replaces.** The spec's review found the rollback graph was a
cycle: T10 copied the Postgres *and* retired the VPS one, and T11's rollback needed the database T10
deleted. Retirement is its own ticket (R-series), behind a stated observation window.

**Write-freeze.** Before any copy, the VPS writer is scaled to 0 and the scale-down is recorded in the
PR. Two live instances writing to two volumes is silent divergence, and D4 leaves the VPS side running
by default.

## 1. Wave 0 — prerequisites; nothing downstream is worth starting until these land

### TP — access and credentials

Six tickets are hard-blocked on access the plan must provision first. One row per credential, with an
owner; this ticket closes when every row has a named holder.

| credential | needed by | why `k8s-reader` is not enough |
|---|---|---|
| VPS cluster age key + read on VPS `Secret`s | §4 in every ticket, T0, T10 | `k8s-reader` cannot read Secrets (spec §9) |
| authentik admin on the VPS instance | T0 | the data is in authentik's DB, not a kubectl role |
| admin kube context on titan | every ticket's `dry-run` | `k8s-reader` is Forbidden for dry-run |
| shell on titan | T3 | PV reclaim is a node-level operation |
| shell on the VPS | T6 | the podman store is outside the cluster |
| `terraform` + OVH write on `tf/` | T12 | DNS and issuer move |

**Exit:** every row names a holder. **Rollback:** n/a.

### T0a — prove what is actually protected (read-only, do this before T0)

The spec's §3 is a hypothesis with three live alternatives, and a DB export cannot falsify it. This
ticket is the falsification, and it is cheaper than the export.

- **Files:** `titan/docs/superpowers/specs/vps-auth-probe.md` — one row per VPS host.
- **Copy:** n/a.
- **Do:** for each host in `td/apply/50-apps/apps/*` with an Ingress, plus `auth.v.arrieta.eu`, record
  `curl -si https://<host>/` status and `Location`, unauthenticated.
- **Exit:** the table distinguishes the three hypotheses — nothing protected / authentik proxy
  providers / network-layer gating. Any host that 302s to `auth.v.arrieta.eu` is authentik-gated; any
  host that 200s unauthenticated is not gated, whatever git implies.
- **Rollback:** n/a — read-only.
- **Gates:** none.

### T0 — export the VPS authentik state

T0a says *whether*; T0 says *with what policy*. It is the source of truth for every auth half.

- **Files:** `titan/docs/superpowers/specs/vps-authentik-inventory.yaml`.
- **Contract:** one entry per Application with: provider type, `ingressUrls`, bound group, policy
  name, and **`access_group` set: yes/no** — the last column is the one that decides whether a host is
  gated open to every authenticated account (spec §9). Plus the outpost configuration.
- **Credential exclusion:** the export contains OAuth2 client secrets. They are **not** written to the
  inventory file. Re-issued per §4, never copied.
- **Also in scope — identity parity (spec §3.3):** user count, group list, and per-provider group
  binding on **both** authentik instances, diffed. This is an exit criterion, not a note.
- **Exit:** inventory committed and reviewed; parity diff attached; every §2 Auth cell confirmed or
  corrected against it.
- **Rollback:** n/a — read-only against the VPS.
- **Gates:** none (a doc-only change), but `kustomize-listing` must stay green.

### T1 — traefik: confirm D5, change nothing

Per spec D5 this is no longer a blocking decision. Titan already runs the required surface:
`apps/teslamate-auth`, `observability/observability-grafana-auth`, `llm/llm-bearer-auth` are live
`traefik.io/v1alpha1` `Middleware` objects and five Ingresses already use `router.middlewares` with a
`websecure` pin.

- **Files:** none. A note appended to `titan/docs/` recording D5 and the F19 chart-version risk.
- **Do:** confirm the three CRD groups the apps consume are present and k3s-owned; confirm no VPS
  traefik manifest is staged for copy (F-B's actual warning).
- **Exit:** `kubectl get middleware -A` returns the three existing objects; the note is committed.
- **Rollback:** n/a.
- **Gates:** `make check-ci`.

### T2 — monitoring decision + scrape re-point

`kube-prometheus-stack` retires rather than migrates: titan's Grafana already reads casa's Prometheus
over the mesh (spec §2). But casa scrapes the VPS today and those targets die with the box.

- **Files:** `nixos-configurations` — the casa Prometheus scrape config and the
  `wireguard`/`public-host.nix` allow on the destination. **Cross-repo: this ticket does not live in
  `titan/` and no `titan/` gate covers it.** State the target file and the PR repo in the ticket body.
- **Do:** re-point casa's VPS scrape targets at titan (F-C carries the port and mesh details). Fold a
  Grafana provision-YAML export of the VPS instance into this ticket — T2 owns the monitoring
  decision, and any alert rule living in VPS Grafana dies with it (spec §2.1).
- **Exit:** casa's targets page shows titan's node, control-plane, kubelet, cAdvisor and
  kube-state-metrics up, and the VPS targets removed.
- **Rollback:** revert the scrape config PR.
- **Gates:** none in `titan/`; the casa repo's own checks.

### T3 — storage preconditions and destination headroom

- **Files:** `titan/apply/` — record the `local-path-retain` + size-from-request rule as policy so
  T8–T10 inherit it rather than rediscover it.
- **Do:** reclaim the `Released` `local-path-retain` coder-home PVs (F-D), then measure what titan
  actually has free against what the arriving set requests (spec §5).
- **Exit:** freed capacity recorded, **and** a headroom verdict covering compute, memory and GPU — not
  only disk. No stateful wave starts until this row is green.
- **Rollback:** n/a — reclamation is destructive, so list every PV removed in the PR before removing
  any.
- **Gates:** `make check-ci`.

### TC — the copy mechanism

The spec's review found no ticket moves bytes. This ticket builds the one mechanism every stateful
ticket reuses, and it restores pre-flight F-G, which gated a working backup path *before* any data
copy and which the spec dropped.

- **Files:** a documented runbook under `titan/docs/`, plus whatever job spec the mechanism needs.
- **Do:** pick one mechanism — the obvious reuse is restic into casa's MinIO, which
  `titan/apply/70-backup/` already owns — and prove it end to end on a scratch volume. State whether
  titan's annotation-driven restic supersedes F-G's parity requirement, or restore F-G as a ticket.
- **Exit:** a volume copied VPS→titan and verified by checksum, and the runbook committed.
- **Rollback:** delete the scratch volume.
- **Gates:** `make backup-coverage`.

## 2. Wave 1 — stateless path builders

These four prove the manifest port, the secret re-encryption and the auth shape at zero data risk.
Each is Ingress-bearing, so each depends on T1 and, for its auth half, on T0/T0a.

### T4 — `home-hass` → `hass.titan.arrieta.eu`

- **Files:** `titan/apply/50-apps/home-hass/home-hass.yaml` (Endpoints + Service + Ingress),
  `titan/apply/50-apps/kustomization.yaml` (+1 line), blueprint `ConfigMap` + `Middleware` + group
  entry per spec §3.2.
- **Copy:** n/a — the data lives on the external HA box, not in the cluster.
- **Do first:** re-verify the external HA address is reachable from titan's network (different LAN than
  the VPS's), **and** decide the HA sub-decision from spec §3.2: browser-only SSO with a documented
  companion-app path, or an allow-listed bypass for the API/websocket surface. Also state current vs
  intended reachability — this host becomes reachable at titan's public IP.
- **Exit:** unauthenticated `curl -si https://hass.titan.arrieta.eu/` → 302 to titan authentik;
  authenticated → 200 and the HA overview renders; a phone companion app still works.
- **Rollback:** delete the Ingress; clients keep using the old URL.
- **Gates:** `make check` (or `check-ci`) **and** `make dry-run DRYRUN_CONTEXT=<admin context>`.

### T5 — `chiclana-hass` → `chiclana-hass.titan.arrieta.eu`

Same shape as T4, second site, same sub-decision. **Files:** as T4 with the name substituted.

### T6 — `strix-scans`

- **Files:** `titan/apply/50-apps/strix/strix.yaml` — the **full** object set from
  `td/apply/50-apps/security/strix.yaml`: `CronJob strix-daily-scan`, `ServiceAccount strix-agent`,
  `ClusterRole strix-reader`, `ClusterRoleBinding strix-reader-binding`, **`ConfigMap strix-config`**
  (omitted by the spec's ticket — `kustomize-listing` will fail without it), and `Secret strix-secrets`
  re-encrypted per §4.
- **Copy:** the results store. **The VPS CronJob persists results via a `hostPath` at
  `/opt/data/strix_runs`, which does not exist on titan.** Replace it with a `local-path-retain` PVC
  sized per spec §5 and carrying the backup annotation, **or** record the deliberate decision to keep
  results ephemeral. As written the spec's ticket loses scan results silently and §5 never fires,
  because there is no PVC to annotate.
- **Do first:** close the second-copy question — a 4.18 GB `strix-sandbox:1.3.0` lived in the VPS
  **podman** store independent of the containerd copy the CronJob uses; it was removed 2026-10-16, and
  if it has reappeared an automated consumer exists and is unaccounted for. Also state the schedule and
  the target namespace, and note the VPS image is `python:3.12.15-slim-bookworm`, not the sandbox image.
- **Exit:** one manual `cronjob suspend=false` run completes and writes to the PVC (or to the recorded
  ephemeral decision).
- **Rollback:** delete the namespace objects.
- **Gates:** `make check` + `dry-run`. No auth half — no host. Record that as a deliberate absence.

### T7 — `bentopdf` and `vert-sh`: host them or retire them

Neither has an Ingress; both are ClusterIP-only and unreachable from outside the cluster today.

- **Step 1 is the operator decision for each**, and it is a decision, not a step to discover later.
- **If hosted:** new `*.titan.arrieta.eu` host + the full §3.2 auth shape. **Files:** one directory per
  app under `titan/apply/50-apps/`, +1 line each in the stage kustomization.
- **If retired:** confirm nothing in-cluster consumes them, and stop. No manifest is written.
- **Exit:** a written decision per app, and for hosted apps the T4 exit pattern.
- **Rollback:** delete the Ingress.
- **Gates:** `make check` + `dry-run` if hosted.

## 3. Wave 2 — stateful

### T8 — `trading-reports` → `tr.titan.arrieta.eu`

Stateful, but with no CNPG dependency, so it does not wait on T10.

- **Files:** `titan/apply/50-apps/trading-reports/trading-reports.yaml` (Deployment + PVC + Service +
  Ingress) + one line in `titan/apply/50-apps/kustomization.yaml`, plus the §3.2 auth objects
  (blueprint `ConfigMap`, `Middleware`, group entry).
- **Secrets:** re-encrypted per spec §4 — `stringData`, git-ignored staging name, recipient count 5.
- **Copy:** 1 Gi PVC via TC's mechanism, after scaling the VPS writer to 0 and recording it. Size per
  spec §5: `max(request, 2 × usage, 2 Gi)`, `local-path-retain`, backup annotation.
- **Do:** re-point any outbound webhook the app was configured with — that lives in the source system,
  not in this manifest (spec §2.2).
- **Exit:** unauthenticated `curl -si https://tr.titan.arrieta.eu/` → 302 to titan authentik;
  authenticated → 200 and a report renders; the PVC reports the class and annotation
  `kubectl -n apps get pvc -o jsonpath` asks for.
- **Rollback:** delete the Ingress; the VPS instance is still running and clients point back at it.
- **Gates:** `make check` (or `check-ci`) **and** `make dry-run DRYRUN_CONTEXT=<admin context>`, plus
  `backup-coverage`.
- **Retirement is not here** — there is no R ticket for trading-reports yet; it runs when the box is
  released.

**This wave's second ticket depends on the first**, because `databasus` re-issues its credentials
against titan CNPG and therefore needs the CNPG objects T10 creates. The spec's wave order had these
inverted.

### T10 — VPS `postgres` → titan CNPG

- **Files:** `titan/apply/30-databases/` for the new `Database`/`DatabaseRole` pairs, and
  `titan/apply/50-apps/<app>/<app>-db.yaml` per consumer. **Placement rule (spec BL-9):** a CNPG
  `Database` must share a namespace with its `Cluster`, so the `-db.yaml` lives in `databases` while
  the app lives in its own namespace. That is why `mealie/` and `sure/` each contribute **two** lines
  to the stage kustomization, `coder/` three and `auth/` five — "one line per app" is wrong and this
  ticket is where it bites.
- **Copy:** dump the VPS Postgres and restore into a CNPG `Database` per consumer, matching the shape
  `auth/`, `coder/`, `open-webui/`, `sure/`, `mealie/` and `60-tesla/` already use. Consumers found
  in-repo: VPS authentik, `databasus`, `postgresus`. **`teslamate` is unconfirmed** — its DSN is inside
  a SOPS secret and must be read, not guessed, before the dump; if it points at the VPS Postgres then
  TeslaMate's driving history is in scope and spec §2.1's `unmeasured` becomes a real migration.
- **Write-freeze:** scale the VPS Postgres Deployment to 0 before the dump and record it.
- **Also archive, even if nothing imports it:** the open-webui VPS volume and the three `unmeasured`
  §2.1 volumes. The dump path is already being built here, so an archive is nearly free and it converts
  three unmeasured losses into recoverable ones.
- **Exit:** each new `Database` reports healthy in CNPG; a row count or checksum comparison per
  consumer database matches the source; the archive exists at a stated path.
- **Rollback:** the VPS Postgres is untouched at this point — that is the whole point of splitting
  retirement out. Scale it back up.
- **Gates:** `make check` (this ticket changes Postgres URLs, so `db-url-check` is specifically
  relevant) + `dry-run`.
- **Retirement is R1, not here.**

### T9 — `databasus`, or its retirement

Depends on T10 for its credentials.

- **Step 1 is the survive-consolidation question** the pre-flight raises: two DB admin UIs is one too
  many, and `postgresus` is already a stub. Retiring is a legitimate outcome and cheaper.
- **Files:** `titan/apply/50-apps/databasus/` + stage kustomization line, if kept.
- **Copy:** 10 Gi PVC via TC's mechanism, after scaling the VPS writer to 0. Size from request with
  the spec §5 headroom rule.
- **Do:** re-issue DB credentials against titan CNPG — never copy the VPS ones (spec §4).
- **Exit:** databasus reaches its target databases from titan; unauthenticated request → 302.
- **Rollback:** point clients back at the VPS instance, which is still running.
- **Gates:** `make check` + `dry-run` + `backup-coverage`.

## 4. Wave 3 — retirement

Each R ticket is gated on a stated observation window with near-zero traffic on the VPS side (spec
§2.2's forcing-function substitute). No R ticket runs just because the migration ticket closed.

### R1 — retire the VPS bare `postgres` Deployment and the `postgresus-pvc-only` stub

Gated on T10 verified and observed. This is the ticket whose rollback was previously impossible.

### R2 — retire the VPS authentik, `ak-outpost-reverse-proxy-outpost` and `bearer-auth-service`

Gated on T0 (inventory taken), on **the explicit ticket set** that replaced each auth half — T4, T5,
T8, T9, T12 — and on T10 and R1, because authentik's own DB is on the Postgres being retired. The
spec gated this on "every app enrolled", which silently included kanghuru in Wave 5; the set is named
here instead.

`bearer-auth-service` is the VPS's answer to what titan already does for `llm`. Confirm titan's bearer
path is equivalent before removing it, and settle the `X-Auth-User` / `X-Auth-Email` response headers
the VPS one emits and titan's does not: either they are needed, in which case titan gains them, or they
are not, in which case spec §2.1's `llm` row stops saying "none".

### R3 — retire the VPS kanghuru

Gated on T12 both halves.

## 5. Wave 4 — last, per D2

### T12 — `kanghuru`

Two halves, in this order.

1. **`kanghuru.titan.arrieta.eu` on titan with forwardAuth, verified.** **Files:**
   `titan/apply/50-apps/kanghuru/` + stage kustomization line + the §3.2 auth objects.
2. **The only DNS change in the plan.** Re-point `kanghuru.es` and `www.kanghuru.es` at
   `<OVH_PUBLIC_IP>` in `tf/`, and move the `le-prod-kanghuru` issuer, `kanghuru-es-cert` and
   `kanghuru-ovh-secrets` to titan.

- **Import before declaring.** `kanghuru.es` is **not** in `tf/` today, so this ticket starts by
  importing the existing records: `tf/`'s own rule is that declaring a record that already exists
  without importing it makes OVH silently create a second copy.
- **Post-renewal NODATA probe (spec §5).** kanghuru has its own `Certificate`, so it is the one
  migrated host exposed to the stale-challenge-node shadowing that took `streaming.titan` dark on
  2026-10-19. After the first renewal following the move, probe `kanghuru.es` for NODATA and declare an
  explicit A record if a stale node is present — the documented `coder.titan` / `streaming.titan`
  remedy.
- **Exit:** half 1 verified before half 2 is raised; after half 2, `kanghuru.es` resolves and serves
  from titan, and the renewal probe is scheduled.
- **Rollback:** half 1 — delete the Ingress. Half 2 — revert the `tf/` PR; TTL is 300 s.
- **Gates:** `make check` + `dry-run` for half 1; `tf/`'s own plan for half 2.

## 6. Gates

`make check` where the age key and network are available; otherwise `make check-ci`, **and the PR
records which ran**. `check` includes `validate` and `db-url-check` (age key) and `chart-values-check`
(network), so it cannot complete in a workspace without them; `check-ci` is the keyless/offline subset
and still covers `kustomize-listing`, `secrets-placement`, `release-secrets`, `secret-refs`,
`ingress-auth`, `blueprint-mount-check`, `backup-coverage`, `crd-check` and `namespace-check`.

**`dry-run` is not part of `check`** and must be run explicitly:
`make dry-run DRYRUN_CONTEXT=<admin kube context>`. It is the only gate that asks the live API server,
and spec §4 leans on it as the thing that catches a `data:`/`stringData` mistake — so a ticket that
runs only `make check` never sees it, and never sees it skip either.

Gates that specifically bite this migration, beyond the always-on set:

| gate | why here |
|---|---|
| `secrets-placement` / `secret-refs` / `release-secrets` | every ticket re-encrypts Secrets into `10-secrets` (spec §4) |
| `ingress-auth` | every Ingress-bearing ticket adds a gated host (spec §3.2) |
| `blueprint-mount-check` | every auth half adds a blueprint `ConfigMap` |
| `db-url-check` | T10 changes Postgres URLs — this gate exists for exactly that |
| `backup-coverage` | every stateful ticket annotates a PVC (spec §5) |
| `namespace-check` | any new namespace (spec §5) |
| `chart-values-check` | only if a `HelmRelease` moves |

Structural rule: **one numbered directory is one stage is one Flux `Kustomization`.** These apps are
not new stages — they are subdirectories under `titan/apply/50-apps/`, one kustomization line per
manifest, and a stateful app contributes two (`<app>/<app>-db.yaml` in `databases` + `<app>/<app>.yaml`
in the app namespace). Whether an app earns the shared `apps` stage at all is decided by the admission
test in `docs/superpowers/specs/2026-10-19-titan-app-scale-out-design.md` §3.1, not by the directory
name.

## 7. Dependency list

Waves are a reading order; this is the actual constraint graph.

```
TP → everything needing credentials
T0a → T0 → {T4, T5, T8, T9, T12} auth halves; T0 also gates R2
T1  → all Ingress-bearing tickets (T4, T5, T8, T9, T12)
T3  → all stateful tickets (T8, T9, T10) — capacity verdict required first
TC  → all stateful tickets (T8, T9, T10) — copy mechanism proven first
T10 → T9 (credentials), → R1 → R2
T7  → R-series only if it retires
T12 → R3
R-series → only after a stated observation window
```

## 8. Program-level acceptance

Before **any** R ticket runs: confirm near-zero hits per VPS host for a stated window (spec §2.2).
D1 has no forcing function — the old names keep working until the box dies, so a missed consumer
breaks silently much later with no visible link to this migration. Traffic on the old names is the
only evidence that the client list in spec §2.2 is complete.
