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
Grafana ──────────────────────────────────────────────────────────> tesla-boards.titan.arrieta.eu
tesla.titan.arrieta.eu/.well-known/appspecific/ ──> nginx (the app's public key; Tesla fetches it forever)
```

Everything is in namespace `apps` except the database, which is in `databases`. All manifests are in
`apply/60-tesla/`.

| component | image | port | exposed as |
|---|---|---|---|
| `teslamate` | `teslamate/teslamate:4.3.0` | 4000 | `tesla.titan.arrieta.eu` |
| `tesla-grafana` | `teslamate/grafana:4.3.0` | 3000 | `tesla-boards.titan.arrieta.eu` |
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
roughly **$65/month**. The values in `apply/60-tesla/teslamate.yaml` are:

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

**What those numbers cost is detection latency, and it compounds.** The state machine doubles the wait
every time a check still finds the car `:asleep` or `:offline` —
`{:next_state, {state, min(interval * 2, asleep_interval())}, data, schedule_fetch(interval, data)}` in
`lib/teslamate/vehicles/vehicle.ex` — so a parked car is polled at 30 s, then 60, 120, 240 … up to the
`POLLING_ASLEEP_INTERVAL` cap of 1800 s. **Nothing pushes to TeslaMate**, so waking the car by hand does
not shorten the wait. Measured 2026-10-18: both cars entered `:offline` at 18:06:53 and no check came due
for the following half hour, which made a woken car look dead. To see state now, use the wake-up control
on the car page, or force a fetch with `kubectl -n apps rollout restart deploy/teslamate` — the state
machine starts at `:start` and fetches immediately, which is why a restart always appears to "fix" it.
Do not lower `POLLING_ASLEEP_INTERVAL` to chase this: at 1800 s a parked car costs ~48 calls/day, and
300 s would put an all-day-asleep car at ~288/day, past the 200/day cap above.

Related, and a reason not to over-react to flapping: current TeslaMate `main` carries a `pre_online_check`
field because MCU2-upgraded cars wake for 2–3 minutes each hour for subsystem checks, and treating that
as a real wakeup forces a ~15-minute full wake. Brief hourly `:online` blips are the car, not the gate.

## 4. Telemetry path

`tesla-fleet-telemetry` is configured by `apply/60-tesla/fleet-telemetry.yaml`. Three settings
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

The forwarder (`apply/60-tesla/forwarder.yaml`) is a dependency-free Node script in a ConfigMap —
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

**Rewritten 2026-10-19 after the first successful bring-up.** Everything below was executed and is
proven; `docs/tesla-telemetry-bringup-2026-10-19.md` is the post-mortem and has the evidence, including
ten ways this went wrong before it went right. Read that file before editing the script.

```fish
./scripts/tesla-push-telemetry-config.sh preflight   # deps, keys, proxy, ca, VINs
./scripts/tesla-push-telemetry-config.sh tls         # once: throwaway loopback TLS pair
./scripts/tesla-push-telemetry-config.sh proxy       # terminal 1 — watch it during push
./scripts/tesla-push-telemetry-config.sh ca          # once per issuer change
./scripts/tesla-push-telemetry-config.sh vehicles    # confirms the token, lists VINs
./scripts/tesla-push-telemetry-config.sh push <VIN>
./scripts/tesla-push-telemetry-config.sh status      # until synced: true
```

Three things this replaced, each of which cost hours the first time:

- **`go install` of the proxy does not work.** The module carries a `replace` directive, so
  `@v0.4.1` cannot resolve. Build from a clone; `preflight` prints the commands.
- **The signing key is not the TLS key.** `-tls-key` and `-key-file` must be different files; the
  proxy refuses otherwise, and rightly so — `-key-file` is the credential that can drive the car.
- **The proxy wants an envelope, `{"vins":[...], "config":{...}}`.** A bare config makes it sign a
  nil map and panic, which surfaces as `curl (92)` or `(52) Empty reply` with no HTTP status. A
  transport-shaped error from a local proxy means read its stderr, not your network.

The token must be a **Fleet API** access token for the owner, minted by your own application — not
the old Owner-API bearer this migration replaces. TeslaMate stores its copy encrypted in the
database; doing the authorization-code flow again (§5a) is less work than decrypting it. Tokens last
about two hours, so expect to re-mint across a long session. The script never puts it on a command
line and never prints it.

**`ca` is mandatory.** Tesla answers `{"error":"ca is not a valid PEM"}` without it. The earlier text
here claimed omitting it made the vehicle fall back to the public CA chain; that was never true and is
the single most expensive sentence in this file. The consequence is an obligation, not just a fact:
**the car pins the chain you send it**, so after any change of issuer — not merely a renewal — the
config must be re-pushed:

```fish
./scripts/tesla-push-telemetry-config.sh ca && ./scripts/tesla-push-telemetry-config.sh push <VIN>
```

**Pairing is per vehicle, happens on the phone, and produces no file.** Open
`https://tesla.com/_ak/tesla.titan.arrieta.eu` (optionally `?vin=<VIN>`) **on the phone** so it deep
links into the Tesla app; in a desktop browser it just renders a page and nothing reaches the app.
An unpaired car is reported honestly as `skipped_vehicles.missing_key`, and no amount of re-pushing
changes that until it is paired. Revocation is on the car's Locks screen.

Nothing below `synced: true` is evidence. Before the car has been told, the cluster logs are quiet
because the car has not been asked, not because anything is broken.

After `synced: true`, the proof is a client connection, not a config echo:

```fish
kubectl --context titan -n apps logs deploy/tesla-fleet-telemetry --tail=20
kubectl --context titan -n apps exec deploy/tesla-redis -- redis-cli info commandstats
kubectl --context titan -n apps exec deploy/tesla-forwarder -- wget -qO- http://127.0.0.1:8080/metrics
```

`socket_connected` with `user_agent=Hermes/*` is the car. `cmdstat_publish` and `forwarded` rising
together is the pipeline. Two traps in those numbers: the per-type counts in `socket_disconnected`
(`V`, `errors`, `total`) are **bytes**, not records — a parked car sends a few hundred of them — and
`forwarded` lags `publish` during a burst because the forwarder serialises frames through a promise
chain, so compare them once traffic has settled. The forwarder logs nothing on success; its metrics
endpoint is the only honest readout.

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
the request line and does nothing else (`apply/60-tesla/auth-callback.yaml`, `replicas: 0`
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

## 5b. Pairing a vehicle — including one owned by a different account

Written 2026-10-19, when the first car paired in one attempt and the second refused with *"only the
vehicle owner can grant"*. Both outcomes are correct behaviour; neither is documented by Tesla where
you would look for it.

Three rules, all learned by being surprised:

1. **Pairing is per vehicle.** Pairing one car says nothing about any other. Each needs its own
   approval, and an unpaired car reports `skipped_vehicles.missing_key` on push — which no amount of
   re-pushing fixes.
2. **The deep link must be opened on the phone.**
   `https://tesla.com/_ak/tesla.titan.arrieta.eu` in a desktop browser renders a page that asks you to
   install the Tesla app and never reaches the app. Send the link to the phone, or add
   `?vin=<VIN>` to pin the vehicle.
3. **Only the vehicle's owner can grant the key**, and the owner's account must already have
   authorized the application with `vehicle_device_data` (or `vehicle_cmds` / `vehicle_location`).
   A shared driver who can *see* the vehicle in the app still cannot pair it — `GET /api/1/vehicles`
   listing the VIN is not the same as being allowed to add keys to it.

Your own account satisfies rule 3 for free: TeslaMate's sign-in created the grant. A second person's
car does not, so their account has to authorize the app once:

```fish
kubectl --context titan -n apps scale deploy/tesla-auth-callback --replicas=1
set -x TESLA_CLIENT_ID <client id>
./scripts/tesla-auth.sh url          # the OWNER of the vehicle opens this and approves
kubectl --context titan -n apps scale deploy/tesla-auth-callback --replicas=0
```

**Stop there — do not run `exchange`.** The pairing page checks that an authorization exists, and
approval creates it; exchanging would mint a second token pair that is needed for nothing and is a
credential with no owner. This is the fallback only if pairing still reports the app unauthorized
after the owner has approved.

Then the owner opens the deep link on their own phone, and the push goes out from your token, which
can already reach the VIN:

```fish
./scripts/tesla-push-telemetry-config.sh push <VIN>
./scripts/tesla-push-telemetry-config.sh status <VIN>
```

**The invariant that makes "do not exchange" more than tidiness:** TeslaMate's `private.tokens` holds
exactly one row, and TeslaMate refuses to start with two (§5a, §7). A second token pair is not merely
unnecessary here, it is actively corrosive to something the migration proved.

Before any of this, confirm the public key is being served — a 404 there produces a misleading
"application has not registered" that looks like an account problem:

```fish
curl -sS -o /dev/null -w '%{http_code} %{size_download}\n' \
  https://tesla.titan.arrieta.eu/.well-known/appspecific/com.tesla.3p.public-key.pem
```

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

That hazard is about pods that **mount** `titan-tls`. `tesla-streaming` does not — Traefik terminates
TLS for it — so it has a different certificate problem, below.

### The streaming host must not serve a wildcard

`tesla.titan.arrieta.eu` and `streaming.titan.arrieta.eu` were both served `titan-tls`, and that was
enough to keep TeslaMate from ever recording a drive.

TeslaMate's stream client is Erlang (`TeslaApi.Stream`, `lib/tesla_api/stream.ex` at v4.3.0). It
passes only `cacerts` and `insecure` to `WebSockex.start_link` and never sets
`{customize_hostname_check, [{match_fun, public_key:pkix_verify_hostname_match_fun(https)}]}`, and
Erlang's **default** hostname matcher does not honour `*.` wildcards — erlang/otp#4321 (ERL-1260),
and TeslaMate #4601 is the same failure against a wildcard Let's Encrypt cert. The certificate can be
perfect and still be refused:

```text
CLIENT ALERT: Fatal - Bad Certificate
 - {:bad_cert, {:hostname_check_failed, {:requested, ~c"streaming.titan.arrieta.eu"},
     {:received, [dNSName: ~c"*.titan.arrieta.eu", dNSName: ~c"titan.arrieta.eu"]}}}
```

Measured 2026-10-18, not theorised: the `Vehicle` process dies on that error, its supervisor restarts
it immediately, and the restart intensity takes the whole application down — 14 restarts, exit 1,
about 14 s per cycle, one `Stream connecting ...` every ~90 ms. **The steady state it produces is
exactly "TeslaMate is not getting any update"**: parked car → quiet; car wakes → crash loop → nothing
recorded → restart → car reads `:offline` again. The wildcard itself is fine for every other consumer;
Python and OpenSSL both validate it, and its chain is publicly trusted.

The fix is `apply/40-certificates/tesla-streaming.yaml`: a single-name `Certificate` for
`streaming.titan.arrieta.eu`, reflected into `apps` as `tesla-streaming-tls`, which the streaming
Ingress now points at. An exact `dNSName` matches under Erlang's default matcher, so nothing needs
patching in the pinned image. The rejected alternative was `TESLA_WSS_TLS_ACCEPT_INVALID_CERTS=true`,
which turns verification off on a connection carrying the vehicle access token.

Check, don't discover:

```bash
# 1. the single-name cert is issued and has no wildcard
kubectl --context titan -n certificates get certificate tesla-streaming -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}{"\n"}'
# 2. what Traefik actually serves for the host TeslaMate dials
python3 -c "import ssl,socket;c=ssl.create_default_context();s=c.wrap_socket(socket.socket(),server_hostname='streaming.titan.arrieta.eu');s.connect(('streaming.titan.arrieta.eu',443));print(s.getpeercert()['subjectAltName']);s.close()"
```

If (2) prints `*.titan.arrieta.eu`, Traefik is falling back to its default certificate because the
Reflector copy has not landed in `apps` yet. That is a real window, not a hypothetical: `stage-apps`
`dependsOn` `certificates` but has no `wait: true`, so the Ingress can be applied seconds before ACME
finishes. It self-heals in under a minute; if it does not, the missing thing is the Secret in `apps`,
not the certificate.

### Verified on 2026-10-19, after it landed

Traefik serves the right thing, and the wildcard is untouched for everything else:

```text
streaming.titan.arrieta.eu     SAN=(DNS: streaming.titan.arrieta.eu)                    to 2027-01-17
randomnothere.titan.arrieta.eu SAN=(DNS: *.titan.arrieta.eu, DNS: titan.arrieta.eu)     to 2027-01-01
```

The claim was then tested **directly** instead of inferred. Both certificates were pulled as DER from
the live endpoint and run through Erlang's own verifier with `dns_id = "streaming.titan.arrieta.eu"`
— `public_key:pkix_verify_hostname/2,3`, OTP 28 from `nix-shell -p erlang`:

| certificate | default match fun — what `TeslaApi.Stream` uses | `https` match fun — the opt-in it never sets |
|---|---|---|
| old `*.titan.arrieta.eu` | **`false`** | `true` |
| new `streaming.titan.arrieta.eu` | **`true`** | `true` |

That reproduces the failure and proves the fix at the mechanism level, on the real certificates: the
default matcher genuinely rejects the wildcard and genuinely accepts the single name. It also rules
out any trust-store explanation, because the `https` match fun accepts the wildcard — exactly what
the upstream advice predicts.

Tested on OTP 28; the image runs OTP 29. The `false` on 28 reproduces the production symptom, so the
two agree on the case that matters, and an exact SAN match is the trivial first clause of the match
fun.

**Still not observed: a real `Stream connected` from a car.** Nothing came online in the window after
this landed, so zero restarts is consistent with the fix and is not evidence for it. The certificate
decision is proven; the end-to-end path is not.

### The DNS trap, because it will happen again

**Issuing this certificate took the host out of DNS.** The DNS-01 challenge creates the in-zone node
`streaming.titan`, and a wildcard cannot match a name that already exists (RFC 4592 closest
encloser), so `streaming.titan.arrieta.eu` started answering NODATA while every other `*.titan` name
kept resolving. The `Certificate` went `Ready` and looked completely healthy throughout, which is why
nothing in this cluster reported it.

The proof, and the shape of the check: `streaming.titan.arrieta.eu` returns NOERROR/no-data for every
record type — no-data, not NXDOMAIN, which is what says the name *exists* — while
`randomnothere.titan.arrieta.eu` still returns the wildcard A. The tell is the leftover
`_acme-challenge.streaming.titan` TXT.

Fixed by declaring an explicit A record in `public-dns-tf` (`64123d4`), the same durable half of the
fix that repo already documents on its `coder.titan` entry. The stale challenge TXT is still in the
zone and is now harmless — **the record is what makes it harmless, so never delete the record because
the TXT came back.**

**Any future single-name `Certificate` under `titan.arrieta.eu` needs its A record declared in
`public-dns-tf` in the same change.** One repo going green while the other goes dark is exactly what
happened here, and no gate in either repo could see it.

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
5. Register the EU partner account, then pair each vehicle — **on the phone, by that vehicle's owner**,
   per §5b. Pairing one vehicle does not cover any other, and a shared account cannot pair a car it
   does not own.
6. Add a payment method and a billing limit — the discount means the expected bill is $0, and the
   limit is what stops a misconfigured poll interval from becoming a surprise.
7. Sign in to TeslaMate, then §5.

## 9. Troubleshooting

| symptom | first suspect |
|---|---|
| TeslaMate sign-in fails | `tesla-oauth` missing or wrong client id; region mismatch between the app and `TESLA_API_HOST` |
| signed in, but "vehicle not responding" | the migrated token is undecryptable — sign out and in again (§7) |
| car is awake but the dashboard stays stale for tens of minutes | the `:asleep`/`:offline` backoff, doubling up to `POLLING_ASLEEP_INTERVAL` (1800 s) — by design, see §3; force a fetch with the wake-up control or a pod restart |
| pod restarts repeatedly; log shows `Stream connecting ...` then `hostname_check_failed` | the streaming host is serving a **wildcard** again. TeslaMate's Erlang client refuses wildcard SANs and crash-loops when a car comes online — §6, and `apply/40-certificates/tesla-streaming.yaml` |
| `streaming.titan.arrieta.eu` does not resolve, yet the `Certificate` says `Ready` | the DNS-01 challenge node is shadowing the `*.titan` wildcard (RFC 4592 closest encloser). Ask with a name that should not exist: if `randomnothere.titan.arrieta.eu` resolves and `streaming` answers NODATA, that is it. Fix is an explicit A record in `public-dns-tf`, not anything in this repo — §6 |
| no live data at all and you cannot tell whether anything ever arrived | ask the forwarder, not the logs: it counts instead of logging. `kubectl -n apps get pod -l app=tesla-forwarder -o wide` then curl its pod IP on `:8080` → `{"connected":true,"forwarded":0,"lastPost":"never"}` means the car has never sent a frame, which is §5 not having taken effect, not a broken pipeline |
| API logs `Account <client_id> must be registered in the current region` | **not** a region mismatch. It means the partner account registration was never done — spec §7 step 3, `POST /api/1/partner_accounts` with `{"domain":"<app domain>"}` (field is `domain`, not `domain_code`) and a partner token whose `audience` is the EU Fleet API base URL. Prove it with `GET /api/1/partner_accounts/public_key?domain=…`, which must return the key served at `/.well-known`. A successful token exchange does **not** prove registration is complete, which is what made this look like a region problem. |
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

### Grafana hostname and the missing auth

Renamed to `tesla-boards.titan.arrieta.eu` on 2026-10-19 (a second Grafana is planned and `grafana.`
would be ambiguous). Three places move together — `GF_SERVER_ROOT_URL`, the Ingress `host`, the `tls`
`hosts` entry — plus **an A record in `public-dns-tf` in the same change**, for the wildcard-shadowing
reason in §6.

Four things that were true at the time of the rename and are worth knowing before you touch this host:

- **Grafana was not behind authentik** until 2026-10-19. The `tesla-grafana` Ingress carried no
  `router.middlewares` annotation while `teslamate` carried `apps-teslamate-auth@kubernetescrd`, so the
  host was reachable by anyone who knew it, gated only by Grafana's own login — even though the outpost
  spec listed it as gated. Verify with
  `kubectl -n apps get ingress tesla-grafana -o jsonpath='{.metadata.annotations}'`; an empty result on
  a cluster predating the fix means unauthenticated. Forward-auth only decides whether the host is
  reachable at all; it never tells the upstream who you are, which is why Grafana used to ask for a
  second, shared password on top of it. There is **no iframe
  anywhere in TeslaMate 4.3** — its Dashboards menu links out with `target="_blank"` — so authentik's
  `X-Frame-Options: DENY` and any SameSite question do not apply to this host. An earlier version of
  this bullet claimed the opposite, inherited from a stale comment in the outpost blueprint rather than
  checked against the app; see the Ingress comment in `apply/60-tesla/grafana.yaml`.
- **The Grafana URL TeslaMate links to is a database row, not a manifest.** It is `grafana_url` in
  `GlobalSettings` (`teslamate/lib/teslamate/settings/global_settings.ex:13`, column added by the 2019
  migration `20191117143038_add_grafana_url.exs`), edited in the UI under **Settings → Dashboards**. A
  migrated database carries the old cluster's value across and no `kubectl` change will move it. Note
  the self-pollution too: if the field is empty, opening a dashboard from the geofence form writes
  whatever origin you arrived from back into it (`geofence_live/form.ex:170`).
- **Grafana's login is authentik's login since 2026-10-20.** Grafana delegates identity to an OIDC
  client declared in `authentik/blueprints-grafana.yaml`, rendered by `scripts/setup-grafana-oidc.sh`
  into `authentik-grafana-blueprint` (what authentik applies) and `tesla-grafana-oidc` (what Grafana
  reads); `make grafana-oidc-check` proves those two, the HelmRelease mount, and the redirect host all
  agree. Merging is not the same as authentik knowing about the client: the worker discovers blueprints
  hourly and can skip a newly mounted one entirely — check with the discovery document probe and, if it
  is missing, apply it directly (`docs/authentik-runbook.md` §5, which is where that is written down and
  why it is not visible in any log). Two things about it are easy to get wrong and hard to notice:
  - **The `profile` scope is load-bearing.** The `groups` claim comes only from authentik's default
    profile scope mapping (`blueprints/system/providers-oauth2.yaml:45`), so dropping it makes
    `role_attribute_path` evaluate against a missing claim and every login silently becomes Viewer.
    Members of authentik's own default `authentik Admins` group get Org Admin; everyone else Viewer.
  - **The endpoint paths are asymmetric.** `authorize`, `token` and `userinfo` are global
    (`/application/o/authorize/`), while issuer and JWKS carry the slug
    (`/application/o/<slug>/jwks/`). Composing `.../o/tesla-boards/authorize/` looks obvious and 404s.
    Read them from `/.well-known/openid-configuration` rather than from prose — including this prose.

  `GF_AUTH_BASIC_ENABLED` stays `true` on purpose: it is the only way in when the OIDC config is the
  thing that is broken. Rollback is one line — `GF_AUTH_GENERIC_OAUTH_ENABLED: "false"` — and it lands
  on the local admin login, not on a public host, because forward-auth is still in front.
- **Stale absolute links live in stored state, not in git.** `grafana.v.arrieta.eu` appears nowhere in
  this repository and nowhere in TeslaMate 4.3.0's source, and TeslaMate has no `GRAFANA_URL` in the
  Deployment or in `teslamate-secrets`. Any link still pointing at an old hostname is in Grafana's
  sqlite on the PVC (dashboard or panel links) or in the TeslaMate database — editing manifests will
  not move it.

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

Retired by measurement on 2026-10-19, and retired **negative**:

| claim | what was actually found |
|---|---|
| the decoded Redis payload shape matches what the forwarder and bridge expect | **cannot be tested yet.** The forwarder reports `{"connected":true,"forwarded":0,"rejected":0,"lastPost":"never"}` over two days, `fleet-telemetry` has logged nothing since its own startup on 2026-10-17T16:34:05 with `log_level: info`, and the bridge has never had a websocket attached. Nothing has ever been published, so §4's synthetic publish is the only way to exercise this path until the car is pointed at it. |
| TeslaMate's own polling survives a car coming online | **it did not.** With a wildcard on `streaming.titan.arrieta.eu` it crash-looped instead — §6. Replaced by the single-name certificate, and **the certificate decision is now proven**: Erlang's default matcher returns `false` for the old wildcard and `true` for the live single-name cert, tested directly against both DER files. What is *still* unobserved is a real `Stream connected` from a car — see §6. |

Retired by measurement on 2026-10-19, and retired **positive** — see
`docs/tesla-telemetry-bringup-2026-10-19.md` for the evidence behind each line:

| claim | what was actually found |
|---|---|
| the vehicle accepts a publicly trusted CA for `telemetry.titan.arrieta.eu` | **moot as posed.** The vehicle does not choose a chain: Tesla requires a `ca` field and the car pins whatever PEM you send. `ca` omitted is not a fallback to the public store, it is a rejected config (`ca is not a valid PEM`). §5 rewritten. |
| the vehicle can be told to stream at all | **yes.** `updated_vehicles: 1`, then `socket_connected user_agent=Hermes/1.16.9 (vehicle_device)`. |
| the decoded Redis payload shape matches what the forwarder and bridge expect | **yes, at small volume.** `cmdstat_publish:calls=4` and `forwarded:4, rejected:0, lastPost:ok`. Not yet exercised at driving volume. |
| the forwarder's `PATTERN` matches the producer's channel | **yes.** Upstream `vinChannel` is `tesla_telemetry_V_{VIN}` (`datastore/redis/redis.go` at v0.9.5) and `tesla_telemetry_V_*` matches it under PSUBSCRIBE; `pubsub numpat` = 1. |

Still open: **sustained volume.** The one session measured was a parked car emitting 650 bytes, and
`forwarded` has never been compared against `publish` across a real trip. Everything above is proven
in kind, not at rate.

One warning attached to that first row of the table above, learned the hard way on 2026-10-19: if you
switch `telemetry.titan.arrieta.eu` to a single-name certificate, **declare its A record in
`public-dns-tf` in the same change.** The DNS-01 challenge node shadows the `*.titan` wildcard and
silently takes the host out of DNS while the `Certificate` reports `Ready`. §6 has the mechanism and
the check.

## 11. Deliberately not done

Remote vehicle commands (no standing vehicle-command proxy — §5 runs one on a laptop, once), Home
Assistant MQTT (`DISABLE_MQTT=true`), elevation enrichment (`OPENTOPODATA_URL` empty), and live
instantaneous power, which the bridge reports as 0. TeslaMate's settings — vehicles, geofences, charge
costs — live in the database and not in git, so they are backed up by the CNPG stream and not by this
repo. Each omission is a separate change with its own spec if it is ever wanted.
