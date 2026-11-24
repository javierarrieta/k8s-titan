# titan TeslaMate → Home Assistant over MQTT — design

Status: **design only, not implemented, and blocked on one operator-side step.** The broker user
does not exist yet, so §5 has to be done by hand on the Home Assistant OS box before anything in
this repo can be tested. Issue #318 is the origin of this document; where the two disagree, this
one is the later word.

This reopens half of what `2026-10-16-titan-teslamate-fleet-telemetry-design.md` §3 T12 closed.
T12 excluded two things together — remote commands and the Home Assistant MQTT integration — and
only the second one is being reopened. Commands stay out, and §10 says why that half still stands.

## 1. Why: the billing arithmetic, and why a second consumer is not free

Home Assistant holds its own Tesla developer application and polls the Fleet API independently of
TeslaMate. Tesla's billing is per **account**, not per application: the `$10/month` individual
developer discount is one pool, and the per-vehicle rate limits are explicitly shared across
applications in one account. Two consumers of one account are therefore not two independent bills;
they are two callers competing for one budget and one throttle.

Measured on developer.tesla.com for November 2026:

| application | usage |
| --- | --- |
| TeslaMate | **$8.20** |
| Home Assistant | **$1.83** |
| total | **$10.03** |

That $0.03 over the discount is what suspended the account, and the suspension is what destroyed
the Fleet Telemetry configurations — see `docs/teslamate-runbook.md` and the 2026-11-23 recovery.
The TeslaMate half of the bill is the expensive one and is being addressed separately by pairing
the Model Y for streaming. This document is about the other half: **make TeslaMate the only Fleet
API consumer**, and make Home Assistant a subscriber to telemetry TeslaMate has already paid for.

The saving is small in absolute terms — $1.83/month. The reason to do it anyway is that the second
consumer is *unbudgeted*. Every polling interval in `apply/60-tesla/teslamate.yaml` was chosen
against a per-vehicle call budget (spec §3.1, and the comment at `teslamate.yaml:95-99` records
the arithmetic). Home Assistant's Tesla integration has never been part of that arithmetic, and
nothing in this repo can see it. A cost nobody is budgeting is a cost that eventually spends the
discount, which is exactly what happened.

## 2. What was measured, and from where

All of this was measured 2026-11-23 from **this workspace, which is a pod on the titan cluster**
(namespace `coder-workspaces`, node `titan`) — not from a laptop. That distinction matters, because
the whole question "can titan reach the broker" is answered by the same probe that answers "can I
reach the broker", and a laptop on the LAN would not have answered it.

- **Reachability: yes.** A TCP connect to the add-on's MQTT listener succeeds from a titan pod.
- **Authentication is required.** An MQTT 3.1.1 `CONNECT` with no credentials returns
  `CONNACK` return code **5 (not authorised)**; an empty-username variant returns the same. This is
  not a config choice — the add-on's own documentation states *"This app does not support anonymous
  logins; all connections must use a username/password to connect."* So the protocol path works end
  to end across the mesh and only a credential is missing.
- **There is no TLS listener.** `8883`, `8884` and `9001` are all **connection-refused** from a titan
  pod — the host answers, nothing is listening. Only cleartext `1883` is live. §4 is the decision
  this forces.
- **There are two brokers in this estate and only one is the target.** The Home Assistant OS Mosquitto
  add-on is the broker Home Assistant uses. Separately, `k8s-casa/apply/50-apps/casa/mosquitto.yaml`
  runs a standalone `eclipse-mosquitto` in namespace `casa` whose config is `allow_anonymous true`.
  **Do not point TeslaMate at it.** It is a different broker, it is anonymous, and its posture is the
  opposite of what §4 assumes.
- **There are two Home Assistant instances and only one is the target.** The HAOS install holds the
  Tesla integration. The `home-assistant` Deployment in namespace `casa` on the casa cluster
  (`k8s-casa/apply/50-apps/casa/hass.yaml`, `hass.local.arrieta.eu`) is a **test instance and is out
  of scope.**

## 3. Direction

One reader of the Fleet API. TeslaMate polls, TeslaMate publishes, Home Assistant subscribes.

```
Tesla vehicles ──Fleet API──▶ TeslaMate (titan/apps) ──MQTT 1883──▶ Mosquitto (HAOS) ──▶ Home Assistant
     └──Fleet Telemetry stream──▶ fleet-telemetry bridge ─┘                              (subscribed)
```

Home Assistant's Tesla usage is **read-only** — no lock, climate, charge-start or wake services are
in use. That single fact is what makes this a swap rather than a redesign, because TeslaMate's MQTT
is read-only by construction and its own Home Assistant integration documents Locks and Climate as
*Not implemented*. Nothing Home Assistant does today is lost. If that ever stops being true, this
design does not extend to it; §10 says what would have to change.

## 4. Transport: cleartext 1883, and what that decision actually buys and costs

**Decision: cleartext MQTT on 1883, with credentials.** Operator's call, recorded here with its
reasoning rather than as a bare outcome, because a decision recorded without its cost is a decision
someone will "fix" by accident later.

What cleartext costs, stated plainly:

- **The broker credential crosses the mesh in plaintext.** Anyone positioned on either network
  segment can capture the TeslaMate MQTT username and password.
- **Two cars' location, occupancy, door and charge state cross it in plaintext.** `teslamate/cars/<id>/location`,
  `is_user_present`, `doors_open`, `sentry_mode` — this is genuinely sensitive data, not a metric.
- **TLS is not free to add here, and the cheap version of it is close to worthless.** The add-on opens
  `8883` when given `certfile`/`keyfile`, but with a self-signed certificate TeslaMate's only option
  is `MQTT_TLS_ACCEPT_INVALID_CERTS=true`, which is encryption *without* authentication. It defeats
  passive sniffing and nothing else, and it is the kind of setting that reads as "TLS is on" while
  being a hole. Note the precedent in this repo: `TESLA_TLS_ACCEPT_INVALID_CERTS` was deliberately
  left out of the same Deployment (`teslamate.yaml:89-93`) precisely because accepting invalid certs
  when a valid one is available is a hole. Here there is no valid one available, so the tradeoff is
  real rather than lazy — but it is still a tradeoff.

Why cleartext is acceptable anyway:

- The path is the **WireGuard mesh and the home LAN**, not the internet. The threat being priced is a
  passive observer on those segments, which is a much shorter list than "anyone".
- **The compensating control is the ACL, not the transport.** §5 scopes the TeslaMate credential so
  that a captured one is nearly useless: write to `teslamate/#` and `homeassistant/#`, read of
  `teslamate/#` only. A captured credential lets an attacker *inject* fake telemetry, not exfiltrate
  anything Home Assistant holds. That is a real reduction in what the plaintext credential is worth,
  and it is the thing that makes this decision defensible rather than merely convenient.
- The data itself is not made more secret by TLS. If location on this path is unacceptable, the
  answer is to stop publishing location, not to encrypt it.

**What would reopen this.** Any of: the add-on's port being published beyond the mesh or the LAN;
the broker being reused by anything that is not this TeslaMate; a certificate with a real chain
becoming available (at which point TLS *with* verification is worth having and
`MQTT_TLS_ACCEPT_INVALID_CERTS` should stay off); or a third car whose telemetry matters more.
This is a decision with an expiry condition, not a permanent property.

## 5. The broker user and its ACL — operator-side, and first

There is nothing to extract from the add-on; a credential is created, not read out.

**User: a local add-on user, not a Home Assistant user.** The add-on supports both. A Home Assistant
user needs no add-on config, but ties the credential's life to a HA user and makes MQTT auth
dependent on Home Assistant's own auth being up — a circularity worth avoiding when Home Assistant
is the consumer. In the add-on's configuration:

```yaml
logins:
  - username: teslamate
    password: <generated>
```

`password_pre_hashed: true` with the `PBKDF2$sha512$…` output of the add-on's own `pw -p` command
keeps it out of the add-on config in plaintext. `homeassistant` and `addons` are reserved names and
cannot be used.

**ACL: opt-in, and not enabled today.** Set `customize: {active: true, folder: mosquitto}`, create
`/share/mosquitto/acl.conf` containing `acl_file /share/mosquitto/accesscontrollist`, then write
that list. `/share` is `/usr/share/hassio/share` on the HAOS host.

**The footgun, which is the reason this section is not a footnote.** Enabling `acl_file` applies it
to *every* user, including the add-on's own `homeassistant` and `addons`. The add-on's docs are
explicit that those two need unrestricted `readwrite #` or Home Assistant's own MQTT breaks. An ACL
written to scope only `teslamate`, which is the natural thing to write, takes down Home Assistant.
The list has to start with them:

```text
user addons
topic readwrite #

user homeassistant
topic readwrite #

user teslamate
topic write teslamate/#
topic write homeassistant/#
topic read  teslamate/#
```

`teslamate` needs **write on two trees**, not one. Vehicle topics go to `teslamate/#`; the discovery
payloads (§6) go to `homeassistant/#`. An ACL that allows only `teslamate/#` produces a state that
is very hard to diagnose: sensors update, entities never appear, and nothing reports an error,
because a denied publish is not a connection failure.

## 6. TeslaMate side — the repo change, and why it is small

The credential does not need a new Secret. `teslamate-secrets` (namespace `apps`) is already pulled
in wholesale by `envFrom` (`teslamate.yaml:55-56`), so adding two keys to it reaches TeslaMate with
no new `secretKeyRef` and nothing for the `secret-refs` gate to complain about. Keys are added with
the quiet sops form from `AGENTS.md` — `sops set <file> '["stringData"]["MQTT_PASSWORD"]'
--value-stdin` — which never prints the value.

The Deployment change is five variables, replacing the block at `teslamate.yaml:64-67`:

```yaml
- name: DISABLE_MQTT
  value: "false"
- name: MQTT_HOST
  value: <add-on address>
- name: MQTT_PORT
  value: "1883"
- name: MQTT_HOME_ASSISTANT_DISCOVERY
  value: "true"
- name: MQTT_HOME_ASSISTANT_DISCOVERY_URL
  value: https://tesla.titan.arrieta.eu/
```

`MQTT_USERNAME` / `MQTT_PASSWORD` arrive via `envFrom` and are deliberately **not** written here —
a `secretKeyRef` for them would be a second path to the same value, and the second path is the one
that drifts. `MQTT_HOME_ASSISTANT_DISCOVERY_PREFIX` is left at its default, `homeassistant`, which
must match Home Assistant's `discovery_prefix`.

**The comment at `teslamate.yaml:64-65` is wrong and must go.** It says `DISABLE_MQTT` plus
`MQTT_HOST` is "the only thing to flip". Home Assistant discovery needs three more variables, and a
future reader who trusts that comment will ship a Deployment that publishes raw topics and creates
no entities.

**Discovery on, not a hand-written `mqtt_sensors.yaml`.** TeslaMate 4.5.0 ships native discovery and
publishes the VIN as the Home Assistant device serial, so the manual include file is no longer
needed. Two documented behaviours to expect rather than debug:

- Enabling discovery while a manual `mqtt: !include mqtt_sensors.yaml` is still present produces
  **duplicate `unique_id` errors**, because the discovered entities deliberately use the same IDs.
  Remove the manual config and its entities first.
- With discovery **disabled**, TeslaMate publishes a zero-byte retained payload to the device
  discovery topic and to 62 legacy topics per vehicle on every start. With it enabled, each restart
  logs one harmless `conflicting MQTT discovery message` warning per legacy topic. Both are cosmetic
  and both will be reported as bugs by whoever sees them first, so they belong in the runbook.

**Reloader needs one annotation to do this, and that is all.** An earlier draft of this document
claimed Reloader was scoped to `coder` and did not watch `apps`. **That was wrong**, and the
cluster disproves it three ways: `reloader.yaml` records that the chart adds its own release
namespace to the watched set and that release lives in `apps`; the live RBAC is a namespaced
`Role/reloader-reloader-role` in `apps` with no ClusterRole anywhere; and `investing-agent` and
`portfolio-prism`, both in `apps`, already carry
`reloader.stakater.com/last-reloaded-from`. What was actually missing is that the TeslaMate
Deployment carried no Reloader annotation at all, so nothing pointed it at `teslamate-secrets`. The
fix is one annotation, named rather than `auto: "true"` per the coder precedent.

Worth recording why this is not "just watch every namespace": spec decision **R3** of
`2026-10-07-titan-reloader-design.md` chose `watchGlobally: false` deliberately, because Reflector
already holds a cluster-wide `secrets: *` held to one purpose by review alone, and Reloader is
purpose-built to read every Secret in whatever it watches. That list has bitten five times
(promtail, open-webui, grafana, mealie, llm) and every one of those was a missing namespace entry or
a missing annotation — which is the failure mode here too, not a case for cluster scope.

## 7. Home Assistant side

Home Assistant already talks to the add-on as its internal broker, so the MQTT integration needs no
new endpoint — the change is that vehicle entities start arriving by discovery instead of by the
Tesla integration. Then:

1. Confirm the MQTT integration is loaded and discovery is enabled on it.
2. Let discovery create the entities for **both** cars, and check them against the car summary in
   TeslaMate — same values, same cars.
3. Only then remove the Tesla integration.
4. Only after a full billing cycle at $0.00, retire the Tesla developer application on
   developer.tesla.com. Until then it is a live credential and a billing line waiting to be
   re-enabled by habit.

## 8. Rollout order, and rollback

Order matters because the failure mode of doing it the other way round is having no vehicle
telemetry at all.

1. Broker user + ACL (§5), then prove an **authenticated** `CONNECT` from a titan pod. Until that
   passes, nothing else is testable.
2. TeslaMate publishes, Home Assistant's Tesla integration still running. Both consumers in
   parallel. This is the safe state and it can be held indefinitely.
3. Discovery entities proven for both cars.
4. Remove Home Assistant's Tesla integration. Watch the developer application's usage for a full
   cycle.
5. Retire the application.

**Rollback is cheap at every step**, which is the good property of this design: re-enabling the
Tesla integration in Home Assistant is a config change, and the developer application is not
deleted until step 5. The one irreversible action is step 5, and it is deliberately last.

## 9. Decisions

**a. Cleartext 1883 with credentials, ACL-scoped.** §4, with its expiry conditions.

**b. Local add-on user, not a Home Assistant user.** §5 — avoids making MQTT auth depend on the
consumer's own auth.

**c. Discovery on.** §6 — 4.5.0 ships it; the manual include file is frozen upstream and will not
gain new sensors.

**d. No `MQTT_NAMESPACE`.** It exists to stop two TeslaMate instances colliding on one broker.
There is one. Setting it "for safety" changes every topic name and would break any hand-written
Home Assistant automation that references `teslamate/cars/…` — a cost paid now for a problem that
does not exist. Revisit if a second instance ever appears.

**e. The casa-cluster broker is not used.** §2 — different broker, anonymous, wrong posture.

**f. Commands stay out.** T12's other half is untouched. Home Assistant is read-only today, so
nothing is lost; and adding commands means a standing vehicle-command proxy, which T12 rejected
because TeslaMate's documented env list has no hook for it. That has not changed.

## 10. Out of scope, deliberately

- **Remote commands** — lock, unlock, climate, charge start/stop, wake. Not in TeslaMate's MQTT, not
  in scope, and if they are ever wanted the design is a vehicle-command proxy, not an MQTT tweak.
- **The casa-cluster Mosquitto and the test Home Assistant.** Both named in §2 so nobody confuses
  them for the target.
- **`power` reporting 0, and no elevation.** Both are recorded in `docs/teslamate-runbook.md` §11
  and are properties of the telemetry path, not of MQTT. Home Assistant inherits them. Anyone
  comparing Home Assistant's Tesla entities before and after will find power has changed from a real
  value to 0 — that is expected, and it is the one regression a user will actually notice.
- **Discovery entity gaps in 4.5.0** (upstream teslamate#5624): `tpms_soft_warning_*`,
  `charge_current_request(_max)`, `climate_keeper_mode`, `center_display_state`, `service_mode`,
  `sun_roof_*`, `download_perc`, `install_perc` are published as topics but not surfaced by
  discovery. If Home Assistant needs one, the fix is a template sensor over the topic, not a patch.
- **The Model Y's missing stream.** As of 2026-11-23 its Fleet Telemetry config is `synced: true`
  with the key grant present and the car has still never connected. MQTT data for that car is only
  as good as its stream, and this change neither fixes nor hides that.
- **Home Assistant's own automations and dashboards.** Rewriting them is the operator's work; this
  document's job is to make the entity names predictable enough to rewrite against.

## 11. What is proven and what is not

**Proven, by measurement on 2026-11-23:** a titan pod can reach the add-on's listener and complete an
MQTT protocol exchange; the broker requires credentials; no TLS listener exists; the November billing
figures; the casa-cluster broker is anonymous and is a different broker.

**Not proven:**

- That an **authenticated** `CONNECT` from a titan pod succeeds. It is the first thing to test and
  it has never been tried, because the user does not exist yet.
- That discovery produces the expected entities for both cars, or that the two cars are the two
  expected cars. TeslaMate's logs never print VINs and `car_id` ↔ VIN mapping is not recorded
  anywhere in this repo, so "both cars appeared" is weaker evidence than it sounds.
- That Home Assistant's existing automations survive the swap. Nobody has enumerated what they
  reference.
- That the Tesla developer application actually goes to $0.00.
- That the Model Y produces any MQTT data at all, given §10's open stream.

## 12. Implementation checklist

Operator-side, in order, none of it in this repo:

1. Add the `teslamate` local user to the Mosquitto add-on (§5).
2. Enable `customize` and write the ACL, `addons` and `homeassistant` first (§5).
3. Restart the add-on; confirm Home Assistant's own MQTT still works.
4. Prove an authenticated `CONNECT` from a titan pod.
5. Hand the address and credential to be committed.

Repo-side, once those are done:

6. `sops set` `MQTT_USERNAME` / `MQTT_PASSWORD` into `apply/10-secrets/teslamate-secrets.yaml`.
7. Edit `apply/60-tesla/teslamate.yaml`: replace the `DISABLE_MQTT` block and delete the stale
   comment.
8. `make check`, then `make dry-run DRYRUN_CONTEXT=<admin context>`.
9. Apply. The annotation added per §6 means Reloader rolls the pod when the Secret changes, so no
   manual `rollout restart` is needed for later edits — but the first apply changes the Deployment
   itself, so it restarts anyway. Confirm the pod is not CrashLooping: TeslaMate refuses to start if
   `MQTT_HOST` is unreachable, which is the loud failure and the one you want.
10. Update `docs/teslamate-runbook.md` §11: Home Assistant MQTT moves from *deliberately not done*
    to done, and record the discovery-restart warnings there so the next person does not file them.

Note for whoever runs step 8: `make check` is red on `main` as of 2026-11-23 for an unrelated
pre-existing `sure-check` failure (`0.7.6-hotfix.2` vs `values.image.tag 0.7.6`). Do not read it as
caused by this work, and do not fix it inside this change.
