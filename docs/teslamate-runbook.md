# TeslaMate runbook

TeslaMate on titan, on the official Tesla Fleet API with self-hosted Fleet Telemetry. The design and
its rejected alternatives live in
[`docs/superpowers/specs/2026-10-16-titan-teslamate-fleet-telemetry-design.md`](superpowers/specs/2026-10-16-titan-teslamate-fleet-telemetry-design.md);
the build order and the reasoning per step live in
[`docs/superpowers/plans/2026-10-16-titan-teslamate-fleet-telemetry.md`](superpowers/plans/2026-10-16-titan-teslamate-fleet-telemetry.md).
This file is what you read at 23:00 when it has stopped working, or when you are about to rotate
something and are not sure what breaks.

**Read this before touching anything: this pipeline has never carried a real frame from a real car.**
Every component was built and checked offline or against the cluster's own API, and the pieces that
could only be proven with a vehicle in front of them are listed in §10 as *not yet proven*, with the
command that would prove them. Do not treat a green `make check` here as evidence that the car is
streaming. Nothing downstream of the car is evidence until `synced: true` (§5).

## 1. Components

```
vehicle ──TLS, SNI passthrough :443──> fleet-telemetry :8443     telemetry.titan.arrieta.eu
              └─ redis PUBLISH tesla_telemetry_V_{VIN} ──> redis (ClusterIP, ephemeral)
                        └─ forwarder PSUBSCRIBE ──HTTP POST──> streaming.titan.arrieta.eu
                                  └──wss /streaming/──> TeslaMate            tesla.titan.arrieta.eu
TeslaMate ──Fleet API (eu) + tuned polling──────────────────────────────> Tesla
          └─> CNPG Database/DatabaseRole `teslamate`  (migrated data)
Grafana ──────────────────────────────────────────────────────────> grafana.titan.arrieta.eu
tesla.titan.arrieta.eu/.well-known/appspecific/ ──> nginx (the app's public key; Tesla fetches it forever)
```

Everything is in namespace `apps` except the database, which is in `databases`. All manifests are in
`apply/50-apps/tesla/`.

| component | image | port | exposed as |
|---|---|---|---|
| `teslamate` | `teslamate/teslamate:4.3.0` | 4000 | `tesla.titan.arrieta.eu` |
| `tesla-grafana` | `teslamate/grafana:4.3.0` | 3000 | `grafana.titan.arrieta.eu` |
| `tesla-fleet-telemetry` | `tesla/fleet-telemetry:v0.9.5` | 8443 telemetry, 8080 status | `telemetry.titan.arrieta.eu` (TLS passthrough) |
| `tesla-redis` | `library/redis:8.8.3-alpine` | 6379 | cluster-internal |
| `tesla-forwarder` | `library/node:22-alpine` + ConfigMap script | 8080 | cluster-internal |
| `tesla-streaming` | `ghcr.io/myteslamate/websocket:0.1.2` | 8081 | `streaming.titan.arrieta.eu` |
| `tesla-wellknown` | `nginxinc/nginx-unprivileged:1.31.7-alpine` | 8080 | `tesla.titan.arrieta.eu/.well-known/…` |

Every image is pinned by digest, including `node:22-alpine`, which is a floating tag upstream and the
only way to make it reproducible is to pin the digest. Refresh digests with the registry API, e.g.:

```bash
curl -s -H "Authorization: Bearer $(curl -s "https://auth.docker.io/token?service=registry.docker.io&scope=repository:library/node:pull" | jq -r .token)" \
  -H "Accept: application/vnd.docker.distribution.manifest.list.v2+json" \
  https://registry-1.docker.io/v2/library/node/manifests/22-alpine -o /dev/null -w '%{header_json}\n' | jq -r '.docker-content-digest[0]'
```

Two components are deliberately single-replica with `strategy: Recreate`:

- **`tesla-streaming`** keeps per-VIN websocket state in memory, so a telemetry POST and the car's
  websocket must land on the same pod. Two replicas means frames land on the pod with no socket.
- **`tesla-grafana`** holds an RWO PVC; a RollingUpdate would strand the new pod on a volume conflict.

## 2. Secrets

Five files in `apply/10-secrets/`, all written by `scripts/setup-tesla-secrets.sh`:

| file | name | namespace | what it is |
|---|---|---|---|
| `teslamate-secrets.yaml` | `teslamate-secrets` | `apps` | `ENCRYPTION_KEY` + the four `DATABASE_*` TeslaMate connects with |
| `teslamate-db-credentials.yaml` | `teslamate-db-credentials` | `databases` | the same password, in the `kubernetes.io/basic-auth` shape CNPG's `DatabaseRole` wants |
| `tesla-grafana-admin.yaml` | `tesla-grafana-admin` | `apps` | overrides the `admin`/`admin` the upstream Grafana image bakes into its ENV |
| `tesla-wellknown.yaml` | `tesla-wellknown` | `apps` | the Tesla application's **public** key, served at `/.well-known/appspecific/` |
| `tesla-oauth.yaml` | `tesla-oauth` | `apps` | `TESLA_AUTH_CLIENT_ID` |

The last two do not exist until the Tesla application has been registered, and are not listed in
`apply/10-secrets/kustomization.yaml` until they do. The script is idempotent **per file** for that
reason: re-running it to add the public key must not regenerate `ENCRYPTION_KEY`, which is what would
happen with a blunt `FORCE=1` and would silently make every vehicle token in the database
undecryptable.

`TESLA_AUTH_CLIENT_ID` is not a secret and would be a ConfigMap if a ConfigMap could fail loudly. A
committed placeholder builds green, reviews green, and breaks sign-in quietly; a missing Secret leaves
the pod `Pending` with an event that names it.

### The Tesla application private key is not in this cluster, and never will be

Nothing running here uses it. It signs `fleet_telemetry_config` and every future vehicle command, and
the only thing that needs it is `tesla-http-proxy`, run once from the operator's laptop
(`scripts/tesla-push-telemetry-config.sh proxy`). There is no container image for it to leak into
even if someone wanted one — verified: no Docker Hub repo for `teslamotors/vehicle-command`, and
release v0.4.1 ships no assets. Keep the private key in a password manager. If it is lost, the
application's keypair must be replaced at Tesla and every paired vehicle re-paired.

### Rotating things

| rotate | command | what else you must do |
|---|---|---|
| DB password | edit both Secret files (or `FORCE=1` the script and re-sync), then `kubectl -n databases apply -f` the `DatabaseRole` | CNPG `ALTER ROLE`s on the Secret change; TeslaMate keeps its old password in its env until restarted |
| `ENCRYPTION_KEY` | regenerate, restart TeslaMate | **every stored vehicle token becomes undecryptable** — sign in again in the UI afterwards. This is not a routine operation |
| Grafana admin password | edit `tesla-grafana-admin.yaml`, restart Grafana | — |
| `teslamate-secrets`, anything | `kubectl --context titan -n apps rollout restart deploy/teslamate deploy/tesla-grafana` | see below |

**Reloader does not watch this namespace.** It is scoped to `coder` in this cluster, so editing
`teslamate-secrets` changes the Secret and nothing else: TeslaMate and Grafana keep running with the
old values in their environment, and no amount of waiting fixes it. The rollout restart above is the
step, not a convenience.

## 3. Polling budget

The Fleet API metered-bills `vehicle_data` at about **$1.50 per 1,000 calls**, with a Discovery-tier
cap of **200 device-data calls per vehicle per day**. TeslaMate's documented defaults — driving 2.5 s,
charging 5 s, online 60 s, asleep 30 s, default 15 s — blow that cap inside a single commute and cost
roughly **$65/month**. The values in `apply/50-apps/tesla/teslamate.yaml` are:

| env | value | why |
|---|---|---|
| `POLLING_DRIVING_INTERVAL` | 30 s | realtime detail comes from the telemetry stream, not from polling; polling only has to notice state changes |
| `POLLING_CHARGING_INTERVAL` | 60 s | charge curves are minutes-slow |
| `POLLING_ONLINE_INTERVAL` | 300 s | a parked online car is not changing |
| `POLLING_ASLEEP_INTERVAL` | 1800 s | an asleep car should not be woken by the poller |
| `POLLING_DEFAULT_INTERVAL` | 120 s | the in-between state |

That is roughly **190 calls/day ≈ $8.60/month**, inside the **$10/month individual-developer
discount**, and under the 200/day cap. It is arithmetic, not a measurement.

| | predicted | measured after a week |
|---|---|---|
| device-data calls/day | ~190 | **not measured — see §10** |
| commands/day | ~0 (no remote commands in v1) | |
| wakes/day | a few | |
| streaming signals/day | large, and irrelevant at $1 per 150,000 | |

If measured device-data is near or above 200/day, **raise the intervals**; do not add a payment method
to cover a mistake. If the bill is above $0, the discount is gone and the intervals need re-deriving
from the numbers, not from this table.

## 4. Telemetry path

`tesla-fleet-telemetry` is configured by `apply/50-apps/tesla/fleet-telemetry.yaml`. Three settings
there are load-bearing and easy to "clean up" by accident:

- **`transmit_decoded_records: true`.** With it off, fleet-telemetry publishes raw flatbuffers and
  the bridge logs `Bad POST body`, returns 200, and TeslaMate never sees a frame. A 200 from the
  bridge is not proof of anything.
- **`records.V: ["redis"]`** with `redis.publish_vin_topics: true`, which publishes one JSON record
  per message on `tesla_telemetry_V_{VIN}`. The MQTT dispatcher was rejected because it publishes one
  message *per field* and drops `vin`, `createdAt` and `tx_type`, which is not enough to rebuild a
  record.
- **`IngressRouteTCP` passthrough at `spec.tls.passthrough`**, not route-level `tls`. On Traefik 3.7.8
  a route has no `tls` field at all; v2-era examples on the internet are wrong. Passthrough is required
  because fleet-telemetry terminates Tesla's mTLS itself — Traefik must not decrypt this connection.

The forwarder (`apply/50-apps/tesla/forwarder.yaml`) is a dependency-free Node script in a ConfigMap —
there is no image-build pipeline in these repos, so reviewable-in-git beat a custom image. It
`PSUBSCRIBE`s `tesla_telemetry_V_*` and POSTs each payload to `http://tesla-streaming.apps.svc.cluster.local/`.
It forwards **bytes, not text**: RESP bulk strings must stay `Buffer`, or a non-UTF-8 payload gets
mangled the day decoded records are ever turned off.

### Verifying it

```bash
make tesla-forwarder-test          # the RESP parser and the end-to-end fake, run from the shipped ConfigMap
```

The synthetic end-to-end check, once everything is deployed — it proves redis→forwarder→bridge→TeslaMate
without a car:

```bash
kubectl --context titan -n apps exec deploy/tesla-redis -- \
  redis-cli PUBLISH tesla_telemetry_V_TESTVIN '{"vin":"TESTVIN","created_at":"2026-01-01T00:00:00Z","trace_id":"0","tick_frequency":"RealTime","data":{"vehicle_speed":{"value":0,"c":0}}}'
kubectl --context titan -n apps logs deploy/tesla-forwarder --tail=5
```

Expected: the forwarder logs a forward for `TESTVIN`. If redis reports `0` receivers, the forwarder is
not subscribed — check its logs for a `PONG` handshake failure before looking anywhere else.

## 5. Pointing the car at it

All of this is the operator's, from their own machine, via `scripts/tesla-push-telemetry-config.sh`:

```bash
go install github.com/teslamotors/vehicle-command/cmd/tesla-http-proxy@v0.4.1   # once
./scripts/tesla-push-telemetry-config.sh proxy    # terminal 1, needs the app private key + proxy cert
./scripts/tesla-push-telemetry-config.sh push     # terminal 2
./scripts/tesla-push-telemetry-config.sh status   # until "synced": true
```

The token it asks for must be a **Fleet API** access token for the owner, minted by your own
application — not the old Owner-API bearer this migration replaces. TeslaMate stores its copy
encrypted in the database; doing the authorization-code flow again (§5a) is less work than
decrypting it.

`ca` is deliberately absent from the request body. Omitting it is what tells the vehicle to validate
`telemetry.titan.arrieta.eu` against the publicly trusted CA chain. **Until this has been done once,
nobody knows whether the vehicle accepts that chain** — it is the spec's open assumption. If the car
connects and fleet-telemetry rejects the handshake, that is suspect number one.

Nothing below `synced: true` is evidence. Before the car has been told, the cluster logs are quiet
because the car has not been asked, not because anything is broken.

Before that, run Tesla's own named preflight — it is a script in the upstream fleet-telemetry repo,
not one in this tree, and it answers the question §5's assumption rests on from outside the cluster:

```bash
git clone https://github.com/teslamotors/fleet-telemetry && cd fleet-telemetry
cat > /tmp/validate_server.json <<'EOF'
{"hostname":"telemetry.titan.arrieta.eu","port":443,"ca":"<the full chain that issued titan-tls>"}
EOF
./tools/check_server_cert.sh /tmp/validate_server.json
```

**Not yet run.** Paste its output here when it has been; until then the public-CA question is an
assumption with a command attached, not a fact.

## 5a. Signing TeslaMate in — the token pair, and why it is not `TESLA_AUTH_CLIENT_ID` alone

**TeslaMate v4.3.0 cannot start itself from a Fleet API client id.** Read in its source at v4.3.0,
not inferred from the docs:

- `teslamate/api.ex` `sign_in/2` accepts only a `%Tokens{access, refresh}` pair, or an
  email-and-password pair for the retired Owner API. There is no OAuth flow in the application.
- The sign-in page is two text boxes, "Access Token" and "Refresh Token", typed by hand.
- `tesla_api/auth/refresh.ex` refreshes with `scope: "openid email offline_access"` hardcoded and
  `client_id: TESLA_AUTH_CLIENT_ID`.
- `tesla_api/middleware/fleet_auth.ex` sends `Authorization: Bearer <TOKEN>` **only when `TOKEN` is
  set** — so the `TOKEN` third-party mode is the only path where TeslaMate does not carry a
  per-account token itself.

Two consequences, both cheap to hit and expensive to diagnose:

1. **The pair has to be minted by *your* application**, because refresh sends `client_id` and Tesla
   rejects a mismatch with `invalid_client` (TeslaMate issue #4091). A pair minted by any other
   client dies at the first refresh, which is at most an hour after sign-in.
2. **The grant must include `vehicle_device_data`.** Tesla requires `scope` on `/authorize`; a token
   granted only `openid email offline_access` authorizes fine and then refreshes fine, and every
   call returns 401 — TeslaMate issue #4081 is exactly that shape.

### The flow

The redirect endpoint is `https://authorize.titan.arrieta.eu/callback` — a Deployment that logs
the request line and does nothing else (`apply/50-apps/tesla/auth-callback.yaml`, `replicas: 0`
between uses). It exists because Tesla only returns the code to a URI the application registered,
and exchanging the code in the cluster would drag `client_secret` into it.

```bash
# 0. one-time, at https://developer.tesla.com: register the application with
#    Allowed Redirect URI(s)  = https://authorize.titan.arrieta.eu/callback
#    Allowed Origin URL(s)    = https://tesla.titan.arrieta.eu
#    Scopes: Vehicle Information, Vehicle Location  (Vehicle Commands NOT needed in v1)

kubectl --context titan -n apps scale deploy/tesla-auth-callback --replicas=1
TESLA_CLIENT_ID=<client id> ./scripts/tesla-auth.sh url      # open the URL it prints
# approve; the browser lands on authorize.titan.arrieta.eu/callback?code=...&state=...
kubectl --context titan -n apps logs deploy/tesla-auth-callback --tail=5
TESLA_CLIENT_ID=<client id> ./scripts/tesla-auth.sh exchange '<the code from that log>'
kubectl --context titan -n apps scale deploy/tesla-auth-callback --replicas=0
```

The script refuses a code with whitespace in it, compares nothing but reports the claimed audience,
and prints the pair with an explicit warning that the refresh token is single use. Check the `state`
in the log against the one the `url` command printed — a mismatched state means the code is not from
your own authorization, and redeeming someone else's code is how an attacker gets your car.

The **client secret** never leaves the operator's machine: `exchange` prompts for it, or reads stdin,
and the token endpoint answers on `fleet-auth.prd.vn.cloud.tesla.com` — not `auth.tesla.com`, which
is where the `/authorize` half lives. Exchanging against `auth.tesla.com` fails in a way that looks
like a bad code.

Paste both values into TeslaMate's sign-in page at `https://tesla.titan.arrieta.eu/sign_in`. After
that, TeslaMate owns the refresh cycle and rotates the refresh token itself; the callback endpoint
plays no further part and stays at `replicas: 0`.

**If sign-in succeeds and every call 401s**, the grant was scoped-down: re-run the flow with the
`vehicle_device_data` scope granted. **If refresh fails with `invalid_client`**, `TESLA_AUTH_CLIENT_ID`
in `tesla-oauth` is not the client id that minted the pair.

## 6. Certificates

`titan-tls` reaches fleet-telemetry as a **Reflector copy**. When the wildcard renews, the copy in
`apps` updates, but the file mounted in a running pod does not change. Check, don't discover:

```bash
kubectl --context titan -n apps exec deploy/tesla-fleet-telemetry -- \
  openssl x509 -in /etc/certs/tls.crt -noout -enddate
kubectl --context titan -n apps get secret titan-tls -o jsonpath='{.data.tls\.crt}' | base64 -d | openssl x509 -noout -enddate
```

The two dates must match. **If they differ, restart the pod** — the car will keep presenting a
handshake the old chain signed and connections will fail in a way that looks like a Tesla problem:

```bash
kubectl --context titan -n apps rollout restart deploy/tesla-fleet-telemetry
```

Same hazard, same fix, for `tesla-streaming` and anything else mounting `titan-tls`.

## 7. Migration

**Done on 2026-10-17.** The trip history moved from techdelivery into CNPG and was verified by row
count: `cars 2`, `drives 3251`, `charges 520368`, `addresses 1025`, `positions 9453030`,
`geofences 19` — identical on both sides, `private.tokens` holding exactly one row, and TeslaMate
starting clean. What follows is how it has to be done, because three plausible approaches failed.

`scripts/restore-now.sh <dump>` is the one that worked. It needs an **admin kube context**: the
read-only `k8s-reader` identity is Forbidden on `pods/exec` in `databases`, which was checked rather
than assumed.

```bash
./scripts/restore-now.sh ./teslamate.dump
```

`scripts/import-teslamate.sh` is the same procedure with a dump-from-source mode (`dump`, `restore`,
`all`) for when the archive has to be taken as well.

Three things about this that are not obvious and cost real time:

- **`pg_restore` has no stdin.** `-` is taken as a literal filename. The archive must be staged as a
  real file inside the pod; `/dev/shm` is used because the CNPG container's root filesystem is
  read-only (`readOnlyRootFilesystem`) and `/tmp` cannot be written. The staged byte count is
  compared with the local one before anything is dropped — a truncated transfer otherwise restores
  partially and looks like success.
- **`--clean` cannot drop TeslaMate's schema.** It emits `DROP TABLE IF EXISTS` without `CASCADE`,
  and the tables hold foreign keys into each other, so the first drop fails, the matching `CREATE`
  then fails `already exists`, and the restore aborts mid-archive. The schema is dropped wholesale
  instead — which is only safe because the target is empty, and the script prints the BEFORE counts
  to prove that before it drops anything.
- **Schema `private` must be dropped too.** TeslaMate keeps its token pairs in `private.tokens`, not
  in `public`. Leaving a previous attempt's rows behind makes the `COPY` append a second pair, the
  primary key then fails on duplicate keys, and TeslaMate refuses to start with
  `Found 2 token pairs!`. This was observed live, not theorised.

`pg_restore` exits 1 for warnings as well as errors, so its exit status proves nothing; the row
counts are the proof. A count mismatch is a failed migration, not a warning.

The old `scripts/migrate-teslamate-db.sh` still exists but counts tables that TeslaMate 4.3.0 does
not have (`trips`, `locations`); its counts were corrected to the real table set, but prefer the two
scripts above, which stage the archive rather than piping it.

After a migration with a **new** `ENCRYPTION_KEY`, the migrated vehicles' stored tokens cannot be
decrypted. Sign out of the vehicle in TeslaMate's Settings, then sign in again through the Fleet API
with `TESLA_AUTH_CLIENT_ID` set. Skipping that leaves a vehicle row that errors on every poll.

## 8. Operator prerequisites, in order

Each of these is outside the cluster and outside git. The manifests do not work without them, and none
of them can be done by the agent.

1. Register a third-party app at developer.tesla.com — **EU region**, Authorization Code + M2M.
2. `scripts/setup-tesla-secrets.sh --genkey` → put the private key in a password manager, paste the
   public key into the application's Public Key field, set the application domain to
   `tesla.titan.arrieta.eu`.
3. `TESLA_CLIENT_ID=<id> scripts/setup-tesla-secrets.sh <public-key.pem>` → commit both new Secret
   files **and list them** in `apply/10-secrets/kustomization.yaml`.
4. Wait for Flux, then prove the key is actually served — pairing fails with a misleading "application
   has not registered" when this 404s:
   `curl -s https://tesla.titan.arrieta.eu/.well-known/appspecific/com.tesla.3p.public-key.pem`
5. Register the EU partner account, pair the virtual key at `https://tesla.com/_ak/tesla.titan.arrieta.eu`.
6. Add a payment method and a billing limit — the discount means the expected bill is $0, and the
   limit is what stops a misconfigured poll interval from becoming a surprise.
7. Sign in to TeslaMate, then §5.

## 9. Troubleshooting

| symptom | first suspect |
|---|---|
| TeslaMate sign-in fails | `tesla-oauth` missing or wrong client id; region mismatch between the app and `TESLA_API_HOST` |
| signed in, but "vehicle not responding" | the migrated token is undecryptable — sign out and in again (§7) |
| no live speed/elevation, but positions appear | that is expected: the bridge reports live power as 0 and there is no elevation enrichment (§10) |
| `synced: false` forever | car asleep or offline; the config only applies on a sync |
| car connects, fleet-telemetry rejects | the public-CA assumption (§5), or the cert hazard (§6) |
| fleet-telemetry logs frames, TeslaMate sees nothing | the forwarder, then the bridge: `make tesla-forwarder-test`, then §4's synthetic publish |
| bridge logs `Bad POST body` | `transmit_decoded_records` got turned off (§4) |
| two bridge pods, frames missing at random | someone set `replicas: 2` (§1) |
| Grafana asks for a login and `admin`/`admin` works | `tesla-grafana-admin` is missing or not mounted (§2) |
| a Tesla manifest builds and nothing changes | it is not listed in a `kustomization.yaml` — `make kustomize-listing` |
| whole host 404s on every path, Traefik log clean | forward-auth is live and authentik is the one answering 404 — see below |
| Traefik logs `middleware "..." does not exist` | wrong provider suffix; `@kubernetescrd` is correct on traefik 3.x, `@kubernetes` is the Ingress provider |

**The 404 that looks like Traefik but is not.** A forward-auth subrequest that authentik answers with 404 is
forwarded verbatim, so the browser sees a 404 from the app's own host and Traefik's log says nothing wrong.
Distinguish it by asking Traefik what it thinks: if the router is serving at all, the 404 came from upstream.
Then test the outpost directly, in-cluster, because Traefik rewrites `X-Forwarded-Host` inbound and an
external curl cannot address a specific provider:

```bash
kubectl -n auth exec deploy/authentik-server -- python -c "
import urllib.request as u, urllib.error as e
for h in ['tesla.titan.arrieta.eu', 'nope.example.com']:
    try:
        r = u.urlopen(u.Request('http://127.0.0.1:9000/outpost.goauthentik.io/auth/traefik',
                                headers={'X-Forwarded-Host': h}))
        print(h, r.status, r.headers.get('Location'))
    except e.HTTPError as x:
        print(h, x.code, x.headers.get('Location'))
"
```

`401` + a `Location` toward a flow is healthy. `404` on both hosts means the outpost has no apps, and the
usual reason is that the proxy provider has no `Application`: the endpoint outposts use to enumerate their
providers is `ProxyProvider.objects.filter(application__isnull=False)`
(`authentik/providers/proxy/api.py:184-188`), and the embedded outpost **suppresses its own empty-provider
warning** (`src/outpost/proxy/mod.rs:129`), so the failure is silent in both processes. This cost hours;
the fix is the `authentik_core.application` entry in `apply/50-apps/auth/tesla-outpost-blueprint.yaml`.

## 10. Not yet proven, and what would prove it

Written at implementation time, before the car has ever talked to this. Each line is a claim the rest of
this file depends on and the command that retires it.

| claim | command that proves it |
|---|---|
| the vehicle accepts a publicly trusted CA for `telemetry.titan.arrieta.eu` | `scripts/tesla-push-telemetry-config.sh status` → `synced: true`, then a frame in fleet-telemetry's log |
| the decoded Redis payload shape matches what the forwarder and bridge expect | §4's synthetic publish, then a frame reaching TeslaMate |
| the Tesla app accepts `https://authorize.titan.arrieta.eu/callback` as a redirect URI | §5a's flow reaching the callback; Tesla rejects an unregistered URI before the login form appears |
| Tesla honours a scoped-down refresh, so a `vehicle_device_data` grant survives `refresh.ex`'s hardcoded `openid email offline_access` | sign in via §5a, then wait past the first token refresh (≤1 h) and confirm `GET /api/1/vehicles` is not 401 — this is the single most likely silent failure in the whole pipeline |
| the polling budget holds | a week of driving, then the developer dashboard's usage page, filled into §3 |
| `nginx-unprivileged`'s UID 101 can read the mounted key | `kubectl -n apps logs deploy/tesla-wellknown` and the curl in §8 step 4 |

Retired by the migration of 2026-10-17: **the migrated database is intact**. §7 records the counts
that proved it, and `private.tokens` holding exactly one row is part of that proof — TeslaMate will
start with zero token pairs and refuse to start with two.

## 11. Deliberately not done

Remote vehicle commands (no standing vehicle-command proxy — §5 runs one on a laptop, once), Home
Assistant MQTT (`DISABLE_MQTT=true`), elevation enrichment (`OPENTOPODATA_URL` empty), and live
instantaneous power, which the bridge reports as 0. TeslaMate's settings — vehicles, geofences, charge
costs — live in the database and not in git, so they are backed up by the CNPG stream and not by this
repo. Each omission is a separate change with its own spec if it is ever wanted.
