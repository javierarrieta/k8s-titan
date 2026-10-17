# titan — TeslaMate on the official Fleet API, with self-hosted Fleet Telemetry

Status: **approved design, not yet implemented.** This is the spec for review; the implementation plan
follows it and nothing here is applied until both are approved.

Everything below marked *verified* was read from a file, a live cluster, or an upstream source during
design. Things that are **assumed** are named as such and re-appear in §9 with the step that settles them.

## 1. Why this is not a lift-and-shift from k8s-techdelivery

`../k8s-techdelivery/apply/50-apps/apps/teslamate.yaml` is *verified* to be: `teslamate/teslamate:4.2.0`,
`replicas: 0`, no PVC, `envFrom` of `teslamate-secrets` + `teslamate-config`. Live on that cluster
(2026-10-16): `deployment.apps/teslamate 0/0`, grafana `1/1`. It is not broken, it is switched off.

The config there is not talking to Tesla directly. Its `TESLA_API_HOST` / `TESLA_AUTH_HOST` are
`https://api.myteslamate.com` with `TESLA_AUTH_PATH=/api/oauth2/v3` and a `TOKEN` in the Secret — the
free **MyTeslaMate** third-party Fleet proxy — and streaming points at `wss://streaming.myteslamate.com`.
So the auth that stopped working was a third party's token exchange, and Tesla's migration of accounts to
the Fleet API is what broke it: the Owner API now answers `403 forbidden, see
https://developer.tesla.com/docs/fleet-api` for migrated accounts (upstream #5399, #5400), and TeslaMate
4.0.x only fixed the part of that it could (HTTP/2 + TLS 1.3 on the auth host, PR #5406).

Two consequences that shape this spec:

- **The version is not the problem.** 4.2.0 is two months old. 4.3.0 (2026-09-29) adds auth fixes worth
  having — #5781 stops following redirects on token refresh so a fleet token is never sent to another
  host, and makes the sign-in page name the actual cause instead of a generic failure — but no version
  fixes an expired third-party token.
- **The old deployment is not a source of truth to copy.** techdelivery's own migration doc
  (`apply/20-infra/vps-to-titan-migration.md`) lists `apps/teslamate` as **unconfirmed** state with its
  DSN locked inside a SOPS Secret. That DSN was read during design: database `teslamate`, user
  `teslamate`, host `postgres.databases` — a bare Postgres Deployment, not CNPG.

## 2. What the official API costs, and why the defaults are unusable

Fleet API is pay-per-use. *Verified* from Tesla's billing page, cross-checked against their own worked
example (384 device-data + 4 commands + 4 wakes = $0.852):

| category | price |
|---|---|
| `vehicle_data` (device data) | ~$1.50 / 1,000 calls |
| Commands | $1 / 1,000 |
| Wakes | ~$1 / 15 |
| Fleet Telemetry signals | $1 / 150,000 |
| Individual-developer discount | **$10 / month** |
| Free "Discovery" caps | 200 device-data, 50 commands, 15 wakes **per vehicle per day** |

TeslaMate's default polling is the opposite of what that pricing allows: driving 2.5 s, charging 5 s,
online 60 s, asleep 30 s. One hour of driving at 2.5 s is 1,440 billed calls — about $2.16/day, and it
passes the 200/day Discovery cap inside the first trip of the day. Tesla's own best-practices page says
it plainly: *"the vehicle data endpoint is meant to be used infrequently and should never be polled
regularly."*

So streaming is not a nicety here, it is what makes the budget fit. Tesla's published example for a
sensible field set is **$0.00636 per hour of driving** via Fleet Telemetry versus $0.12 the same hour via
`vehicle_data`. With telemetry carrying the realtime path and `POLLING_*` tuned down, a single car lands
well inside the $10 discount. Without telemetry, it does not.

That is the whole argument for the extra components in §4. It is also why **a payment method and an
explicit billing limit are operator prerequisites**: a billing limit of 0 with no card means the
application is *disabled* when it trips, not throttled.

## 3. Decisions

| # | Decision | Rejected alternative |
|---|---|---|
| T1 | **Official Tesla Fleet API**, self-registered third-party app | MyTeslaMate proxy (what broke, third party holds the tokens) and Teslemetry (paid, and its streaming is incompatible with TeslaMate) |
| T2 | `teslamate/teslamate:4.3.0` + `teslamate/grafana:4.3.0`, pinned | `:latest`. Both `4.3.0` tags *verified* present on Docker Hub |
| T3 | `TESLA_API_HOST=https://fleet-api.prd.eu.vn.cloud.tesla.com`, `TESLA_AUTH_HOST=auth.tesla.com`, `TESLA_AUTH_PATH=/oauth2/v3` | The NA host. The cluster's S3 backups are `eu-west-1` and the domain is `.eu` |
| T4 | **Self-hosted Fleet Telemetry** streaming (option "B2") | Poll-only with tuned intervals — viable, but the data quality drop is the thing the user is installing this to avoid |
| T5 | fleet-telemetry dispatcher = **Redis pub/sub** | **MQTT**, which was the original plan and is wrong: `datastore/mqtt/mqtt_payload.go` publishes *one message per field* on `<topic_base>/<VIN>/v/<field>` with the bare value as payload, discarding `vin`, `createdAt` and `tx_type`. The bridge needs one whole record. Re-assembling records from a per-field firehose means time-window coalescing over drive data. Redis does `client.Publish(channel, entry.Payload())` — **one message per record**, already the decoded JSON |
| T6 | The Redis→bridge forwarder is a **dependency-free Node script in a ConfigMap**, run by `node:22-alpine` | Building a small image. *No build pipeline exists* — no Dockerfile, goreleaser or buildx workflow in k8s-casa, k8s-techdelivery, nixos-configurations, public-dns-tf or halogen-flash-flake. Raw `net.Socket` for RESP and built-in `fetch` means no npm install, no registry, and the code is reviewable in git like every other manifest |
| T7 | `ghcr.io/myteslamate/websocket:0.1.0` as the streaming bridge, **1 replica, `strategy: Recreate`** | Writing the transform ourselves (~400 lines of protocol translation, permanently ours). The image is anonymously pullable (*verified*: manifest fetch 200 with an anonymous pull token). Its own chart documents why it cannot scale: per VIN the telemetry POST and the websocket must land on the same pod, because the tag/lastValue state is in-memory |
| T8 | **Everything in namespace `apps`**, one new directory `apply/50-apps/tesla/` | A `tesla` namespace. `titan-tls` is already reflected into `apps`, so `apply/40-certificates/titan-wildcard.yaml` is not touched and no namespace is added to `namespaces.yaml`. AGENTS.md's allow-list rule stays intact |
| T9 | `IngressRouteTCP` with SNI match + `tls.passthrough: true` for `telemetry.titan.arrieta.eu`, fleet-telemetry terminating its own TLS from `titan-tls` | A second public port. Tesla requires mTLS terminated on the telemetry service, and passthrough is what preserves that. *Verified* feasible: titan runs `rancher/mirrored-library-traefik:3.7.8` and `ingressroutetcps.traefik.io` v1alpha1 exists |
| T10 | **Fresh `ENCRYPTION_KEY`**, sign in again | Carrying techdelivery's key. That key protects stored Owner-API tokens which are dead anyway; carrying it means a secret with no purpose and a real blast radius |
| T11 | CNPG `Database` + `DatabaseRole` like coder's, password in a `kubernetes.io/basic-auth` Secret carrying `cnpg.io/reload` | A hand-created role. `auth/authentik-db.yaml` already records the two traps: `login: true` is required and silent when missing, and the reload label belongs on the Secret, not the DatabaseRole |
| T12 | **Remote commands out of v1** (no standing vehicle-command proxy) | Running `tesla-http-proxy` as a service. TeslaMate's documented env list has no hook for it, so it buys nothing until it does |
| T13 | `POLLING_*` tuned explicitly, and the billing limit set in the portal | Tesla's defaults. §2 is the arithmetic that rules them out |
| T14 | Accept that rotating `teslamate-secrets` does **not** restart TeslaMate | Adding `apps` to Reloader. Reloader is scoped `watchGlobally: false, namespaces: [coder]` (`2026-10-07-titan-reloader-design.md` §3 R3) and widening it is a separate decision with its own blast radius. `ENCRYPTION_KEY` rotation is not a routine operation; when it happens, the rollout is manual and that is documented here rather than silently wrong |

### 3.1 The polling values, with the arithmetic

Upstream labels every `POLLING_*` variable "do not alter this setting unless you are certain of the
implications", and that warning is right in general — it is written for the Owner API, where polling was
free. Here the pricing in §2 is the reason it must be altered, and the target is the 200 device-data
calls/vehicle/day Discovery cap. With Fleet Telemetry carrying `Location` and `VehicleSpeed` at 10 s, the
poll path only has to detect state transitions, so it can be coarse:

| variable | from | to | a typical day costs |
|---|---|---|---|
| `POLLING_DRIVING_INTERVAL` | 2.5 s | **30 s** | 45 min driving → 90 calls |
| `POLLING_CHARGING_INTERVAL` | 5 s | **60 s** | 30 min charging → 30 calls |
| `POLLING_ONLINE_INTERVAL` | 60 s | **300 s** | 2 h awake → 24 calls |
| `POLLING_ASLEEP_INTERVAL` | 30 s | **1800 s** | 48 calls |
| `POLLING_DEFAULT_INTERVAL` | 15 s | **120 s** | small |

About 190 calls/day ≈ $0.29/day ≈ **$8.60/month** — inside both the cap and the $10 discount, with the
streaming signals themselves a rounding error at $0.006/hour of driving. These are starting values, not
revelations: §8.6 is what adjusts them.

## 4. Data path and inventory

```
vehicle ──TLS, SNI passthrough :443──> fleet-telemetry :8443     telemetry.titan.arrieta.eu
              └─ redis PUBLISH tesla_telemetry_V_{VIN} ──> redis (ClusterIP, ephemeral)
                        └─ forwarder PSUBSCRIBE ──HTTP POST──> streaming.titan.arrieta.eu
                                  └──wss /streaming/──> TeslaMate            tesla.titan.arrieta.eu
TeslaMate ──Fleet API (eu) + tuned polling──────────────────────────────> Tesla
          └─> CNPG Database/DatabaseRole `teslamate`  (migrated data)
Grafana ──────────────────────────────────────────────────────────> grafana.titan.arrieta.eu
```

| component | image | port | host |
|---|---|---|---|
| TeslaMate | `teslamate/teslamate:4.3.0` | 4000 | `tesla.titan.arrieta.eu` |
| Grafana | `teslamate/grafana:4.3.0` | 3000 | `grafana.titan.arrieta.eu` |
| fleet-telemetry | `tesla/fleet-telemetry:v0.9.5` | 8443 (TLS), 8080 status | `telemetry.titan.arrieta.eu` |
| redis | `library/redis:8.8.3-alpine` | 6379 | cluster-internal |
| forwarder | `library/node:22-alpine` + script ConfigMap | 8080 | cluster-internal |
| streaming bridge | `ghcr.io/myteslamate/websocket:0.1.0` | 8081 | `streaming.titan.arrieta.eu` |
| well-known | `nginxinc/nginx-unprivileged:1.31.7-alpine` | 8080 | `tesla.titan.arrieta.eu/.well-known/…` |

Every tag above was checked against the registry on 2026-10-16. `node:22-alpine` is the one floating tag
in the set — no `node:22.20.x-alpine3.23` tag exists — so the forwarder Deployment pins it **by digest** at
implementation time, which is the only way to make a moving alpine tag reproducible.

`tesla.titan.arrieta.eu` already resolves publicly and answers 404 from Traefik (*verified* 2026-10-16),
so every hostname above works the moment an Ingress exists.

## 5. Manifests

Eight files under `apply/50-apps/tesla/`, each listed in `apply/50-apps/kustomization.yaml` —
`make kustomize-listing` is in `check-ci` because an unlisted manifest is a manifest that does not exist.
Order matters and is the apply order Flux uses: `teslamate-db.yaml` before `teslamate.yaml`, redis before
fleet-telemetry, fleet-telemetry before forwarder, bridge before TeslaMate.

**Two phases, deliberately.** Phase 1 is the database, the migration and the whole telemetry pipeline —
fleet-telemetry, redis, forwarder, bridge, well-known — with TeslaMate absent, so §8.1 to §8.4 can be
proven against redis and the bridge logs before anything depends on them. Phase 2 is TeslaMate and
Grafana. Deploying TeslaMate first would mean running it on the polling budget alone, which is the one
configuration §2 shows is unaffordable.

**`teslamate-db.yaml`** — `Database` + `DatabaseRole` in namespace `databases` (a CNPG Database must
share a namespace with its Cluster, so it lives beside the app in git and beside `postgres` in the
cluster, exactly like `coder/coder-db.yaml`).

**`teslamate.yaml`** — Deployment + Service + Ingress. `strategy: Recreate` is not needed (no PVC) but
harmless; `VIRTUAL_HOST=tesla.titan.arrieta.eu`, `CHECK_ORIGIN=true`, `DISABLE_MQTT=true`, `TZ=UTC`,
`TESLA_API_HOST`/`TESLA_AUTH_HOST`/`TESLA_AUTH_PATH`/`TESLA_AUTH_CLIENT_ID` per T3,
`TESLA_WSS_HOST=wss://streaming.titan.arrieta.eu`, `TESLA_WSS_USE_VIN=true`, and the tuned
the `POLLING_*` values from §3.1. `TESLA_WSS_TLS_ACCEPT_INVALID_CERTS` is deliberately **absent** —
techdelivery's security report removed it once and a publicly trusted cert should not need it. If §8.5
proves otherwise, that is a finding about the cert, not a licence to re-add it.

**`grafana.yaml`** — PVC (`local-path`, 1 Gi) + Deployment (`Recreate`, per the RWO rule) + Service +
Ingress. `GF_SERVER_ROOT_URL` set to the grafana host.

**`wellknown.yaml`** — Tesla requires the application public key at
`https://tesla.titan.arrieta.eu/.well-known/appspecific/com.tesla.3p.public-key.pem` and re-checks it
forever (pairing continuity, announced 2024-02-02). TeslaMate will not serve it, so: a static nginx with
the key baked from a ConfigMap, plus an Ingress path rule for `/.well-known` on the same host. The
**private** half of that keypair never appears here — it lives in `apply/10-secrets/` and is used only by
the one-off Job in §7.

**`fleet-telemetry.yaml`** — Deployment + Service + `config.json` ConfigMap + `IngressRouteTCP`.
The config is the load-bearing part:

```json
{ "host": "0.0.0.0", "port": 8443, "status_port": 8080,
  "namespace": "tesla_telemetry",
  "transmit_decoded_records": true,
  "rate_limit": { "enabled": true, "message_interval_time": 30, "message_limit": 1000 },
  "records": { "alerts": ["logger"], "errors": ["logger"], "V": ["redis"] },
  "redis": { "addrs": ["tesla-redis.apps:6379"], "publish_vin_topics": true },
  "tls": { "server_cert": "/etc/certs/tls.crt", "server_key": "/etc/certs/tls.key" } }
```

`transmit_decoded_records: true` is what makes the Redis payload the JSON the bridge parses.
`publish_vin_topics: true` is required — the producer refuses to start with neither it nor
`subscriber_set_prefix`, because nothing would be published. The resulting channel is
`tesla_telemetry_V_{<VIN>}` (`BuildTopicName` + a literal `{}` Redis Cluster hash tag).

**`redis.yaml`** — `library/redis:8.8.3-alpine --save '' --appendonly no`, ClusterIP, no PVC. Pub/sub only; nothing
here needs to survive a restart, and a lost frame is one frame, not a lost trip.

**`forwarder.yaml`** — Deployment + the script ConfigMap. Contract: PSUBSCRIBE
`tesla_telemetry_V_*>` over a raw RESP socket, and for each message POST
`{"message":{"data":"<base64 of the payload>"}}` to the bridge. No parsing of the payload — it is
forwarded byte-for-byte, base64-wrapped. Reconnect with backoff; log every non-2xx. The bridge returns
200 even on a bad body (it logs `Bad POST body`), so **the forwarder's own logs are the only place a
shape mismatch shows up** — which is why §8.4 exists.

**`streaming.yaml`** — the bridge, 1 replica, `Recreate`, `ENFORCE_TOKEN` from a Secret, Ingress on
`streaming.titan.arrieta.eu`. Its `/streaming/` websocket path matches what TeslaMate requests, and its
`GET /` health endpoint is the probe.

## 6. Secrets and the database migration

`apply/10-secrets/`, sops-encrypted, recipients from `.sops.yaml` only — never `--age` on the command
line, which silently drops every other keyholder:

- `teslamate-secrets.yaml` — `ENCRYPTION_KEY` (fresh, T10), `DATABASE_USER`, `DATABASE_PASS`,
  `DATABASE_NAME`, `DATABASE_HOST=postgres.databases`, and the bridge token.
- `teslamate-db-credentials.yaml` — `kubernetes.io/basic-auth`, `username: teslamate`, labelled
  `cnpg.io/reload`.
- `tesla-app-keys.yaml` — the secp256r1 private key used for pairing and for signing
  `fleet_telemetry_config`. Used by one Job, mounted by nothing that faces the network.

Migration, in order:

1. `pg_dump -Fc teslamate` from techdelivery's `postgres.databases`. **Needs an admin context** —
   `k8s-reader` is Forbidden on `pods/exec` there, which was checked rather than assumed, and the DB size
   is therefore still unknown.
2. Apply `teslamate-db.yaml` on titan and wait for the role to converge. A `DatabaseRole` without
   `login: true` produces "role teslamate is not permitted to connect" and nothing else.
3. `pg_restore --no-owner --no-privileges` into the CNPG cluster.
4. Apply the app. TeslaMate runs its own Ecto migrations on boot; 4.2.0 → 4.3.0 is forward-only and
   automatic.
5. Sign in. Fresh `ENCRYPTION_KEY` means the migrated tokens are unreadable by design (T10).

Rollback is trivial and worth stating: the source database is untouched, techdelivery already runs at
`replicas: 0`, so rolling back is scaling titan's TeslaMate to zero.

## 7. Operator prerequisites — the parts git cannot do

In order, each one blocking the next:

1. Create the third-party app at developer.tesla.com (**Authorization Code and Machine-to-Machine**),
   application domain `tesla.titan.arrieta.eu`, scopes covering vehicle data and `vehicle_location`.
   Application names that already exist are auto-rejected, so pick a specific one.
2. Generate the secp256r1 keypair, put the private half in `tesla-app-keys.yaml`, serve the public half at
   `/.well-known/appspecific/com.tesla.3p.public-key.pem` (§5) and merge.
3. Generate a partner token and call `POST /api/1/partner_accounts` for the **EU** region. Pairing fails
   with a misleading "application has not registered" if this is missing or the well-known path 404s.
4. Set the redirect URI to TeslaMate's callback under `VIRTUAL_HOST` — read the exact path from the
   sign-in page rather than trusting this document.
5. Pair the virtual key: open `https://tesla.com/_ak/tesla.titan.arrieta.eu` and approve in the Tesla
   phone app, logged in as the same account.
6. Push `fleet_telemetry_config` **through the vehicle-command proxy** — Tesla's docs are explicit that
   the config is signed by the app private key and the proxy is how it gets signed. One-off Job with the
   key from `tesla-app-keys.yaml`; the field set from Tesla's own sample (`VehicleSpeed` and `Location`
   at 10 s, `Soc`/`Odometer`/`EstBatteryRange` at 60 s, doors/lock on change).
7. Wait for `fleet_telemetry_config` to report `synced: true` before believing anything downstream.
8. Add a payment method and set a billing limit in the dashboard.

## 8. Verification

Offline, as always: `git add -A && make check`, then `make dry-run DRYRUN_CONTEXT=<admin context>` — the
`IngressRouteTCP` and the CNPG objects are exactly the kind of thing only the API server can reject.
`crd-check` walks the new `Database`/`DatabaseRole` against `vendor/cnpg-crds/`.

Then, in order, each step gated on the one before:

1. **Hostname and cert.** `curl https://telemetry.titan.arrieta.eu:443` completes a TLS handshake against
   the wildcard and Traefik routes it to fleet-telemetry rather than the HTTP router. Then run upstream's
   `check_server_cert.sh` with `hostname`/`port`/`ca` — that is the exact check Tesla says to run.
2. **Registration.** `fleet_status` shows the app key on the vehicle; `fleet_telemetry_config` reports
   `synced: true`.
3. **Frames arrive.** fleet-telemetry logs a connection; redis receives
   `tesla_telemetry_V_{VIN}`; the forwarder logs a POST; the bridge logs `Subscribe from …`.
4. **The shape assumption is proven, not assumed.** Capture one real Redis payload and diff it against
   what `transformMessage` reads: top-level `vin`, `createdAt`, and `data[]` entries carrying
   `value.locationValue` / `doubleValue` / `intValue` / `stringValue`. This is the single highest-risk
   seam in the design, because a mismatch is silent on both ends.
5. **TeslaMate.** Sign in, watch a drive, and confirm positions arrive on the stream rather than from a
   poll. Confirm TeslaMate validated the bridge's certificate without
   `TESLA_WSS_TLS_ACCEPT_INVALID_CERTS`.
6. **Budget.** After a week of real driving, read the usage page. If device-data is anywhere near the
   Discovery cap, the `POLLING_*` values are wrong, not the dashboard.
7. **Migration.** Row counts for `trips`, `drives`, `charges` match the source; Grafana dashboards load
   against the new host.

## 9. Not proven / accepted

- **Whether the vehicle accepts a publicly trusted CA for the telemetry hostname.** Tesla's announcement —
  *"Fleet Telemetry onboarding no longer requires submitting a CSR to Tesla. Vehicles running firmware
  2024.26.4 or later can receive configurations through the Vehicle Command Proxy"* — is *verified*, and
  third-party tooling passes `ca: null` "for publicly trusted certs like Let's Encrypt", but that is
  third-party evidence. §8.1 settles it. If it fails, the fallback is a Tesla-signed cert, not
  `TESLA_WSS_TLS_ACCEPT_INVALID_CERTS`.
- **The exact decoded-JSON shape fleet-telemetry puts on Redis.** Inferred from the bridge's parser and
  `transmit_decoded_records`. §8.4 settles it.
- **TeslaMate's redirect URI path.** Read it from the app in §7.4; do not copy it from here.
- **The size of the source database.** `pods/exec` is Forbidden for the read-only identity.
- **fleet-telemetry's and redis's real container users.** Set `runAsUser`/`fsGroup` from the image, not
  from memory — the same rule techdelivery's AGENTS.md learned the hard way with nginx's UID 101.
- **Live instantaneous power reads 0** through this bridge, and elevation needs its optional OpenTopoData
  sidecar. Both are upstream limitations, accepted for v1.
- **No remote commands, no Home Assistant MQTT** (T12, `DISABLE_MQTT=true`).
- **TeslaMate settings live in its database, not in git.** Anything changed on the settings page is
  out-of-band state this repo cannot see — the same class of problem AGENTS.md records for `kubectl edit`.
- **Firmware floor.** Streaming needs 2024.26.4+ (2025.20+ on Atom-model S/X). A car below that gets
  polling only, and the polling budget in §2 applies in full.
