# Tesla Fleet Telemetry bring-up — 2026-10-19 post-mortem

The car was pointed at `telemetry.titan.arrieta.eu` for the first time on 2026-10-19 and the pipeline
delivered its first frame end-to-end. It took most of a day. This file records every obstacle, what
actually caused it, and the change that makes the next one shorter. It is written as a list of
symptom → cause → fix → guardrail because that is the shape the lessons have.

Read this before touching `scripts/tesla-push-telemetry-config.sh` or believing anything in
`docs/teslamate-runbook.md` §5 written before this date.

**Vehicle identifiers are redacted in this file, and must stay that way.** A VIN is a personally
linkable identifier, one of the vehicles here belongs to a second person, and this repository is
public. Use `<VIN-A>` / `<VIN-B>` in docs and commit messages; the real values live in the app's
vehicle list, not in git.

## What is now proven, with the evidence

| claim | evidence |
|---|---|
| the virtual key pairs | `tesla.com/_ak/tesla.titan.arrieta.eu` opened **on the phone**, approved in the Tesla app |
| Tesla accepts the config | `{"response":{"updated_vehicles":1}}` for `<VIN-A>` (the operator's car) |
| an unpaired car is refused, not silently dropped | `{"skipped_vehicles":{"missing_key":["<VIN-B>"]}}` (a second owner's car) |
| the car connects through the Ingress | `socket_connected user_agent=Hermes/1.16.9 (vehicle_device) network_interface=wifi` |
| the intake publishes to Redis | `cmdstat_publish:calls=4`, no `redis_err` |
| the forwarder delivers to the bridge | `{"connected":true,"forwarded":4,"rejected":0,"lastPost":"ok"}` |
| the Redis key pattern matches | upstream `vinChannel` = `tesla_telemetry_V_{VIN}`; `pubsub numpat` = 1 |

Not proven: sustained volume (the car was parked — 650 **bytes** in a 167-second session), the second
car (unpaired), and anything measured over a week of driving.

## The issues

### 1. `tesla-push-telemetry-config.sh proxy` could never start

**Symptom.** The proxy exits immediately, or the operator assembles the invocation by hand.

**Cause.** The script passed `--insecure --server-address`. Neither flag exists. v0.4.1 deliberately
ships no way to disable TLS — there is a comment in `cmd/tesla-http-proxy/main.go` explaining that
this was a decision, not an omission. The real flags are `-cert -tls-key -key-file -host -port
-timeout -verbose`, plus `-key-name`/`-vin`/`-session-cache` from `pkg/cli/config.go`.

**Guardrail.** Flags were read out of the v0.4.1 source before the rewrite, not from a blog post or a
memory. When a tool's interface is the thing that keeps failing, the source is the only acceptable
citation.

### 2. `go install ...tesla-http-proxy@v0.4.1` does not work

**Symptom.** `go install` fails to resolve the module.

**Cause.** The module has a `replace` directive, so a versioned `go install` of a subpackage cannot
resolve. It has to be built from a clone.

**Guardrail.** The script now prints the clone-and-build commands instead of an impossible one. An
instruction that cannot be executed is worse than none, because it consumes a debugging cycle.

### 3. The signing key was being used as the TLS key

**Symptom.** The proxy refuses to start and tells you to generate a new TLS key.

**Cause.** `-tls-key` and `-key-file` both pointed at `~/tesla/private-key.pem`. The proxy is right to
refuse: the signing key is the credential that can drive the car, and reusing it for transport
encryption is a needless second exposure.

**Guardrail.** `tls` generates a throwaway loopback pair and `cmd_tls`/`cmd_proxy` both hard-refuse
when the two paths are equal. The old script also shipped a `proxy-cert.pem` described as "the cert
Tesla issued for your application domain" — it was self-signed and Tesla had never heard of it. A
comment that misattributes a credential invites exactly this confusion.

### 4. The request body had the wrong shape, and the proxy panicked

**Symptom.** `curl: (92) HTTP/2 stream 1 was not closed cleanly: INTERNAL_ERROR`, then over HTTP/1.1
`curl: (52) Empty reply from server`. No HTTP status at all.

**Cause.** The script posted the telemetry config bare. The proxy wants an envelope:

```json
{"vins": ["..."], "config": { ...hostname, port, ca, fields... }}
```

With no `config` key, `params.Config` unmarshals to a nil `jwt.MapClaims`, and
`authentication.SignMessage` does `message["iss"] = ...` on it — `panic: assignment to entry in nil
map`. The Go server closes the connection without writing a response, so curl reports a transport
error.

**This cost the most time of anything on this list.** Three wrong diagnoses were made in sequence —
HTTP/2 negotiation, an old curl, an empty token — because the error looked like a transport problem.
Each was plausible and each was tested, and the actual cause was only visible in the proxy's own
terminal, which was not read until late.

**Guardrail.** Two changes, and the second is the important one:
- the script builds the envelope with `jq` and refuses to send if `config.ca` is not a plausible PEM;
- **when a local proxy answers with a transport error and no status code, read the proxy's stderr
  before theorising.** A panic there is a fact; everything else is inference. The script now prints
  that instruction on exactly those curl errors.

### 5. A 1071-character bearer header looked like the culprit

**Symptom.** `GET /` on the proxy returned 403 over both h1 and h2; a POST with the real token
returned nothing.

**Cause.** Not the header. Every POST to that endpoint panicked regardless of the token. The long
token was a red herring, and `suspect-chars=5` turned out to be five `-` characters, which are legal
in base64url and therefore in a JWT.

**Guardrail.** The token is now checked only for embedded whitespace (which really does produce a
malformed header) and is never printed. Length and character class are not evidence of anything here.
Also: the token belongs in a header file with 0600 perms, not in argv — `ps` shows argv to every user
on the machine, and the old script put `Authorization: Bearer $TOKEN` on the command line.

### 6. `ca` is required, not optional

**Symptom.** `{"error":"ca is not a valid PEM"}` from Tesla, for every VIN.

**Cause.** Both the script and runbook §5 asserted that omitting `ca` was a deliberate choice that
told the car to validate against the public CA chain. That was never true. Tesla requires a PEM.

**Fix.** `ca` is fetched from the live endpoint (`openssl s_client -showcerts`), the leaf is dropped,
and the remaining chain is embedded via `jq --rawfile`.

**Guardrail, and a new operational obligation:** the car now **pins** the chain we send. When the
wildcard certificate's issuer changes, the pushed config is stale and the car will stop connecting.
`tesla-push-telemetry-config.sh ca && ... push` is required after any issuer change, not just a
renewal. Runbook §5 now says this.

### 7. Pairing happens on the phone, and produces no file

**Symptom.** `https://tesla.com/_ak/<domain>` opened in a desktop browser shows a page asking to
install the Tesla app, and nothing appears in the app.

**Cause.** It is a deep link, not a web page. It has to be opened on the phone so it hands off to the
app, where a trusted user authorises the key onto the vehicle. Runbook §5 implied pairing produced a
file to keep; it does not.

**Guardrail.** §5 rewritten. Pairing is per vehicle and can be done at any time later; the optional
`?vin=` parameter pins which car. Revocation is on the car's Locks screen, not in the app.

**And pairing can only be done by the vehicle's owner.** Discovered later the same day on the second
car: a shared account that can see the vehicle and whose token lists the VIN is refused with *"only
the vehicle owner can grant"*. The owner's account must also have authorized the application first
(Tesla's step 1). §5b is the procedure, including why the owner's authorization should be approved
but **not exchanged** — TeslaMate holds exactly one token pair and a second one is a credential with
no purpose here.

### 8. `socket_disconnected` counts bytes, not records

**Symptom.** `{"V":"650","errors":"84","total":"734"}` looked like 650 vehicle records, while the
forwarder reported `forwarded: 1`. That suggested a 650-to-1 loss and sent a whole investigation
chasing Redis routing, RESP parsing and rate limits.

**Cause.** `SocketManager.ReportMetricBytesPerRecords` does `RecordsStats[recordType] += byteSize`.
Those numbers are **bytes**. 650 bytes is a parked car sending a few records, which matched
`cmdstat_publish:calls=3` exactly.

**Guardrail.** Recorded here and in §10. The general form: a counter whose name does not say its
unit is a counter you must read the source for before reasoning from it. `forwarded` and `publish`
both being small was the real signal; the mismatch was invented.

### 9. `forwarded` lags `publish` during a burst

**Symptom.** `publish:calls=3` while `forwarded:1`.

**Cause.** The forwarder serialises every frame through a promise chain and increments `forwarded`
after each HTTP round-trip completes. Mid-burst it always reads low. Later: `publish=4`,
`forwarded=4`, `rejected=0`.

**Guardrail.** Compare those two counters after traffic has settled, not during. The forwarder logs
nothing on success by design, so its silence is not evidence either way — the metrics endpoint is the
only honest readout.

### 10. Tooling friction that was not the repo's fault, but cost time anyway

- Fleet API access tokens last about two hours and were being re-typed between terminals. Losing one
  mid-session caused a detour.
- `set -Ux` in fish writes a universal variable to `~/.config/fish/fish_variables` — a token on disk
  in plaintext, forever. Use a 0600 file for a session, or re-mint.
- The read-only `k8s-reader` identity is Forbidden on `pods/exec` and `services/proxy`, so the
  forwarder's metrics and `redis-cli` were unreachable from this session by design. That is correct
  behaviour and worth knowing in advance: the two commands that settle the question need an admin
  context.

## The procedure that works, start to finish

From the operator's machine, two terminals. `preflight` first is new and would have caught items 1, 2,
3 and 5 before they became mysteries.

```fish
./scripts/tesla-push-telemetry-config.sh preflight
./scripts/tesla-push-telemetry-config.sh tls          # once
./scripts/tesla-push-telemetry-config.sh proxy        # terminal 1 — watch it during push
./scripts/tesla-push-telemetry-config.sh ca           # once per issuer change
./scripts/tesla-push-telemetry-config.sh vehicles     # confirms the token and lists VINs
./scripts/tesla-push-telemetry-config.sh push <VIN>
./scripts/tesla-push-telemetry-config.sh status       # until synced: true
```

Pairing, once per vehicle, **on the phone**: `https://tesla.com/_ak/tesla.titan.arrieta.eu`,
optionally `?vin=<VIN>`.

Then the cluster side, which needs an admin context for the last two:

```fish
kubectl --context titan -n apps logs deploy/tesla-fleet-telemetry --tail=20
kubectl --context titan -n apps exec deploy/tesla-redis -- redis-cli info commandstats
kubectl --context titan -n apps exec deploy/tesla-forwarder -- wget -qO- http://127.0.0.1:8080/metrics
```

`socket_connected` with a `Hermes/*` user agent is the car. `cmdstat_publish` and `forwarded` rising
together is the pipeline. A parked car produces a few hundred bytes; judge volume only after a drive.

## What to do differently next time

1. **Read the tool's source before its documentation, and the tool's stderr before theorising.**
   Items 1, 2, 4 and 5 were all solvable in minutes by reading something that already existed.
2. **Prove a script can run before documenting it.** `tesla-push-telemetry-config.sh` was committed,
   reviewed and cited in the runbook without ever having been executed. `preflight` exists so the next
   version can be exercised without a car, a token and a phone.
3. **Do not assert a negative about a remote API from reasoning.** "Tesla accepts a public CA chain"
   was an assumption dressed as a fact for two days, and the honest label was already in §10 — the
   table said *not proven*, and §5 then described it as a decision.
4. **Never put a credential in argv or in an error path.** The old script's failure output could
   surface the bearer token.
5. **Name units in counter names, or read the source before reasoning about them.** Item 8.
