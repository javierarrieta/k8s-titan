# Investing-agent (hermes) bring-up on titan — 2026-10-26

Hermes, the Nous Research investing agent, moved out of `../k8s-techdelivery` into this cluster:
namespace `apps`, object names unchanged, image pin unchanged. The manifest is
`apply/50-apps/investing-agent/investing-agent.yaml` and its header is the **design** — why
`apps`, why `local-path-retain`, why the Secret had to be re-encrypted. This file is the **log**:
what was measured before merging, what has run, and what is still unproven. Read the header for
*why*; read here for *did*.

## Measured before merging

| claim | evidence |
|---|---|
| every offline gate passes on the branch | `make check` on `feat/investing-agent`: leak-check, kustomize-check, kustomize-listing, `validate`, secrets-placement, release-secrets, db-url-check, oidc-check, grafana/observability/open-webui-oidc-check, mealie-check, sure-check, crd-check (39 objects), namespace-check (201 objects), tesla-forwarder-tests — all green |
| the re-encrypted Secret actually decrypts | `make validate` → `OK: apply/10-secrets/investing-agent-secrets.yaml` with the Coder workspace age key. 5 recipients, `titan-k8s` `age1t5z4e…` present, techdelivery's cluster key absent |
| nothing was dropped in the re-encryption | key set compared against `../k8s-techdelivery`'s own file: `OPENAI_BASE_URL`, `HERMES_DASHBOARD_BASIC_AUTH_USERNAME`, `HERMES_DASHBOARD_BASIC_AUTH_PASSWORD_HASH` — three keys, same names, both sides |
| the source is stopped before this starts | k8s-techdelivery PR #171 (`scale to 0`) merged `2026-10-26T07:39:02Z`, before this branch's head commit. There is no window in which both gateways run. |
| the image pin is real, and the semver move is still ahead of us | Docker Hub API on `/v2/repositories/nousresearch/hermes-agent/tags/v2026.9.24/` returns the tag (amd64, 968 MB); `v0.22.5` also answers 200 |
| the new process tree does what its comment claims | 14 assertions against a fake `hermes`, run under both `sh` and `bash`: both children start; after `exec` the container PID *is* the gateway; SIGTERM reaches the gateway and the container is gone in <20 ms; a gateway crash exits the container non-zero ~1 s later; a dashboard death does **not** end the container, which is exactly why the liveness probe is load-bearing. The old `… & wait` form was run for comparison and did stay Running with a dead gateway. |
| the source volume's real host path | `kubectl get pv -o custom-columns=…` on the techdelivery host: `investing-agent-pv-claim` → `/opt/k3s/volumes/pvc-21879166-bb63-4c16-a2d2-9f99120058d4_apps_investing-agent-pv-claim`. **Not `/opt/data`** — that is the *container* mount path, and the first `du -sh` measured a different directory entirely. The source cluster's `local-path` uses `nodePathMap: /opt/k3s/volumes`, not the k3s default `/var/lib/rancher/k3s/storage` |
| the source tree fits the claim | `du -sh` on the path that PV names, 2026-10-26: **161M** against a 10Gi claim — roughly 64x headroom. The claim is the source's own value and was kept rather than trimmed, because `allowVolumeExpansion: false` makes trimming irreversible |
| the live API server accepts every object in the tree | `make dry-run DRYRUN_CONTEXT=<admin>`, 2026-10-26, on the rebased branch: `00-bootstrap ok (56)`, `10-secrets ok (33)`, `20-infra ok (29)`, `40-certificates ok (3)`, `50-apps ok (73)` — 5 stages built, 5 accepted. This is the first live validation of the new PVC and Deployment, and the first time that gate reached `50-apps` in weeks |
| the built object is what was written | `kubectl kustomize apply/50-apps` → `Deployment apps/investing-agent` replicas 1, `strategy: Recreate`, `terminationGracePeriodSeconds: 60`, readiness + startup + liveness all present, PVC on `local-path-retain` |

## What the dry-run caught on the way

The first attempt did not pass. It stopped at `10-secrets` with
`failed to convert new object (apps/investing-agent-secrets; /v1, Kind=Secret): illegal base64
data at input byte 3`, and named `llm/llm-bearer-token` alongside it. A Secret's `data:` values
are base64 by contract and a sops ciphertext is not base64, so the API server refuses the tree
while it is still encrypted — Flux decrypts before it applies, so only this gate ever sees it.

Three things came out of that one error:

- this Secret moved to `stringData` (values byte-identical, compared per key by sha256);
- `llm-bearer-token` had the same defect on main and had been silently blocking the gate for
everything behind it — fixed in PR #166, which is what let `20-infra` onwards be checked at all;
- `secrets-placement` now rejects `data:` under `apply/10-secrets`, so it cannot come back.

## Pre-flight: the size, and the wrong directory it took to get it

`/opt/data` is what the container mounts, not where the source cluster keeps the bytes. The first
`du -sh /opt/data` returned 11M and measured something else — the operator's instinct was right,
and the PV listing settled it:

```
CLAIM: investing-agent-pv-claim
PATH:  /opt/k3s/volumes/pvc-21879166-bb63-4c16-a2d2-9f99120058d4_apps_investing-agent-pv-claim
du -sh <that path>  ->  161M
```

161M against a 10Gi claim, so the `allowVolumeExpansion: false` trap is not a live risk and the
copy is a seconds-long transfer, not one to schedule. The lesson is in the method: with
`local-path`, a volume's host path is derived from a random PV name and a cluster-specific
`nodePathMap`, so it is read off the PV object and never guessed from the mount path.

## What still has to happen, in order

1. merge. The PVC binds, the pod schedules, the app boots against empty state — harmless, and it
   does mean the first minutes of cron runs are against nothing.
2. rsync **from the source PV's host path** —
   `/opt/k3s/volumes/pvc-21879166-bb63-4c16-a2d2-9f99120058d4_apps_investing-agent-pv-claim` on the
   techdelivery host — into titan's directory for the claim, **read off titan's own PV** after it
   binds (`kubectl --context titan get pv -o custom-columns=CLAIM:.spec.claimRef.name,PATH:.spec.local.path`)
   rather than globbing a guessed name — then `chown -R 10000:10000`. The pod is uid/gid 10000 with fsGroup 10000; a tree owned by
   anything else reads as a corrupt DB. The two clusters use different `nodePathMap` roots
   (`/opt/k3s/volumes` there, `/var/lib/rancher/k3s/storage` here) and the directory name embeds
   the PV name, which is random — so neither end of this copy can be named in advance. Read both
   off their PV. The container path `/opt/data` appears in neither.
3. `kubectl -n apps delete pod -l app=investing-agent`. The running pod holds the old files open,
   so a copy that lands underneath it is not picked up until the process restarts. Not
   `kubectl scale` — replicas is git-managed and Flux reverts it at the next sync.
4. prove it: the dashboard answers through the Service (`http://investing-agent.apps.svc`), one
   cron run completes, and the DB is not reported corrupt.

`make dry-run` and the `du -sh` pre-flight have both been done; see the table above.

## Not proven

- **the migrated state works.** Steps 1-4 are that proof and none of them have run. Until they do,
  this PR is a manifest the API server accepts, not a working migration. Server-side dry-run
  proves admission, not runtime: it has never seen the pod schedule, the volume bind, or SQLite
  open the restored tree.
- **nothing here is backed up.** techdelivery protected this claim with the `backup-investing-agent`
  restic CronJob; titan ships no generic PV backup (AGENTS.md, "Backups"). Accepted in PR #162 as a
  decision, not an oversight — closing it is its own change.
- **a gateway that is alive but wedged is invisible.** It exposes no health endpoint, so nothing can
  probe it. `exec` fixed the *dead* gateway; wedged is still dark.
- **cold start against the migrated tree is unmeasured, but the tree is 161M**, so the startupProbe's
  ~5 minutes is ample by a wide margin. If the pod ever fails to become Ready, the volume is not why.
- **why `gateway.lock` ever goes stale is unknown.** The manifest deletes it on every start, which
  was inherited from the source without anyone recording the failure it papers over. With the gateway
  now at PID 1 a crash restarts the pod cleanly, so if the lock turns out to have been guarding
  nothing, deleting it unconditionally is what lets a half-started gateway look healthy. Worth one
  look at the techdelivery logs before the source teardown removes the evidence.
- **`/bin/sh` inside the image is assumed, not inspected.** It is proven by the source pod having run
  the same `command` for months, which is decent evidence but not the same kind.
- **the 512Mi `emptyDir` at `/tmp` is a hard cap whose failure mode is eviction, not an error.** If
  SQLite FTS spill grows into it, kubelet evicts the pod and on a single node that takes the gateway
  with it.

## Gate gap this migration exposed — closed

Nothing used to check that a hand-written Deployment's `envFrom.secretRef.name` resolves to a Secret
that exists. `make release-secrets` walks `HelmRelease` objects only, and `make secrets-placement`
proves placement, encryption and listing, never consumers. A typo'd name built green and produced a
Pending pod naming a Secret that plainly exists.

`make secret-refs` (#165) closes it: `envFrom`, `secretKeyRef`, volume mounts and the protected-Secret
references of every hand-written workload, with an allow-list for in-cluster-produced Secrets that is
`apps/titan-tls` and nothing else.

## Live edits made inside the volume, 2026-10-26

**Why this section exists.** Git pins an image, three env vars and a PVC. Everything hermes actually
does is decided by files inside the claim — `config.yaml`, two `.env` files, a profile tree — and no
gate in this repo can see any of them. Every check stayed green while two of those files were wrong.
Anyone who copies this volume inherits all of the below silently, which is why it is written down
rather than left in a terminal scrollback.

| file | change | why | backup | proof it took |
|---|---|---|---|---|
| `profiles/invest/config.yaml` | `model.default` `Qwopus3.6-35B` → `halogen-qwen3.8-flash-next`; `model.base_url` `:8001` → `:8731` | `:8001` is decommissioned. `:8731` serves exactly one model, so the id was not a free choice — `/v1/models` returned `['halogen-qwen3.8-flash-next']` | `config.yaml.bak-20261026` | gateway up, and a conversation completed over Discord |
| `profiles/invest/.env` | `DISCORD_BOT_TOKEN` commented out | the token there was revoked at Discord; replacing it with `default`'s live token produced `Profile 'default' and 'invest' both configure discord with the same credential — refusing to start the duplicate`. `discord:` in that config has no `enabled:` key, so the token's presence is the switch | `.env.bak-20261026` | `gateway_state.json`: `discord.state: connected`, `served_profiles: [default, invest]` |
| `.hermes/.env.backup` | moved out of the volume; `ls "$HERMES_HOME"/.env*` no longer lists it. Intended destination `/root/hermes-env-backup-2026-10-26` on the titan host — not re-verified from here | held superseded tokens that made token-shaped grep forensics ambiguous — three matches, two of them dead ghosts | `/root/hermes-env-backup-2026-10-26` (unverified) | `ls "$HERMES_HOME"/.env*` no longer lists it |
| `.hermes/active_profile` | created, then removed | experiment: making `invest` the launch profile. The gateway refused to start — `invest` was never folded into multiplex — and the pod crash-looped seven times | n/a, deleted | absent; pod healthy |
| `profiles/invest/.env` ownership | restored to `hermes:hermes` | `kubectl exec` runs as root, so a file rewritten that way changes owner | n/a | `ls -la` shows `hermes hermes` |

**Pre-existing, not from today:** `.hermes/.env.new` (18 B) and `.hermes/.env.tmp` (309 B), both dated
May 29 — leftovers from someone's earlier in-place edit. They are credential-shaped files sitting next
to the real one and are worth deleting on purpose rather than by accident.

**What to re-check after any future copy of this volume.** The failure mode that bit was a service
moving and a profile config not following it, which is invisible from outside and silent from inside:
the pod is Ready, the dashboard answers, cron runs, and every model call fails.

Read the endpoint the profile itself names, then ask it, and confirm the platform state:

```
kubectl --context titan -n apps exec deploy/investing-agent -- sh -c 'grep -A4 "^model:" "$HERMES_HOME/profiles/invest/config.yaml"'
kubectl --context titan -n apps exec deploy/investing-agent -- sh -c 'grep -o "\"state\": \"[a-z]*\"" "$HERMES_HOME/gateway_state.json"'
```

Then curl the `base_url` that first command printed, at `/v1/models`, and expect `200`. Three
commands, and they are the only ones that would have caught anything this section documents.

## Ingress, added 2026-10-27 — amended 2026-10-28, now gated by authentik

The dashboard went from in-cluster-only to a public hostname during the bring-up follow-up, not
before merging. The add is deliberate and is now the design record at the bottom of
`apply/50-apps/investing-agent/investing-agent.yaml`; this section is the log of it.

**Amended 2026-10-28, because PR #192 put a forward-auth gate in front of this host and three
sentences below said the opposite of what the file does.** The original wording is kept rather than
silently rewritten — it is the log of what was decided on 2026-10-27, and the parts about the
credential and the entrypoint pin still hold. What changed: the `Ingress` now carries
`traefik.ingress.kubernetes.io/router.middlewares: apps-teslamate-auth@kubernetescrd`, so every
request reaches authentik before it reaches the pod and the dashboard's own login is the *second*
gate rather than the only one. The mechanism, the policy it inherits (any authentik-authenticated
account — `access_group` is unset, and nothing in this tree can attest that set is a set of one), and
the answers that tell you whether it is working are all on the `Ingress`. `make ingress-auth`
appears with that change and is what stops the annotation from being prose only.

- **The host** is `investing-agent.titan.arrieta.eu` — one label deep, exactly the wildcard
  `*.titan.arrieta.eu`'s depth, so the add needed no new Certificate and no DNS record, and no edit
  to `apply/40-certificates/titan-wildcard.yaml`: the Secret arrives through the Reflector
  allow-list and `apps` was already on it.
- **SUPERSEDED 2026-10-28 — this bullet read "No forward-auth middleware was added."** There is one
  now, and it needed no blueprint edit: the outpost's provider is `forward_domain` over
  `titan.arrieta.eu`, so this host was already covered by it. Kept because the half about the
  credential is what the rate-limit decision still rests on. The dashboard's own login
  (`HERMES_DASHBOARD_BASIC_AUTH_*`) was then the only gate, which is the property that made a public
  hostname safe to plan — and the credential behind it is machine-generated, operator-attested
  2026-10-27, which is the half of that sentence the rate-limit decision turns on.
- **The router is pinned to the `websecure` entrypoint** —
  `traefik.ingress.kubernetes.io/router.entrypoints: websecure` on the `Ingress` annotations, the
  same line `apply/50-apps/llm/llm.yaml` draws for its bearer token — so cleartext is refused rather
  than redirected, because the dashboard's own credential is in play either way. There is no global
  HTTP→HTTPS redirect on this cluster's Traefik to lean on instead, which was measured, not assumed:
  `http://meals.titan.arrieta.eu/` (no pin) answers **200** over cleartext and
  `http://llm.titan.arrieta.eu/` (pinned) answers **404**. So the annotation is the whole mechanism
  and nothing in this repo notices it being removed — `make ingress-auth`, new with the 2026-10-28
  amendment, reads the middleware annotation and deliberately not this one.
- **Nothing rate-limits the host.** Narrowed 2026-10-28, not closed: a stranger on the internet can no
  longer make this pod run scrypt at all, because authentik answers them first, but nothing has been
  verified to throttle a signed-in user hammering `/login`. Before the gate the dashboard's login was
  the only gate on a public hostname, so failed logins were unthrottled at the proxy. Traefik 3.7.8
  ships an OSS `rateLimit` middleware and
  the `Middleware` CRD is already used by `observability-grafana-auth@kubernetescrd`, so it is a
  two-line add — deliberately not added. The decision, and the residual it leaves, are in
  *Why no rate limiter — decided, not deferred* below.

### The credential behind the gate, measured 2026-10-27

`HERMES_DASHBOARD_BASIC_AUTH_PASSWORD_HASH` was read out of `apply/10-secrets/investing-agent-secrets.yaml`
with sops to answer one question — is the hash the defense here? — and only its **parameters** are
recorded below. The digest and the salt are credential material and stay in the Secret.

| field | value | reading |
| --- | --- | --- |
| id | `scrypt` | memory-hard KDF; the right family, not MD5 or bare SHA-256 |
| N | 16384 = 2^14 | cost parameter |
| r | 8 | block size, 1024 bytes |
| p | 1 | parallelism |
| salt | 18 bytes | base64, 24 chars |
| output | 32 bytes | base64, 44 chars |

- **16 MiB and a full mixing pass per attempt** (128 · N · r). That is real work per guess, and it is
  the throttle the proxy is not providing: every failed login costs this 1.5-CPU pod the same 16 MiB
  and the same CPU, which is why no rate limiter has been added and is also the DoS surface one would
  have bought back.
- **It is below OWASP's current floor.** The Password Storage Cheat Sheet asks for scrypt at
  N=2^17, r=8, p=1 — 128 MiB — or an equal-defence row. Ours is 8× lighter than that row, and OWASP's
  equal-defence table pairs N=2^14 with p=**5**, so N=2^14 at p=1 sits under every combination it
  lists. Not a defect introduced here, and not fixable from this repo either: nothing in this tree sets
  those parameters — the container's only `env` entries are `HERMES_HOME`, `HERMES_CRON_TIMEOUT` and
  `TMPDIR`, everything else arrives by `envFrom` — so they are the image's own.
- **What the hash cannot prove is the part that matters — and that question is now closed.** A hash says
  nothing about the entropy of the input it was computed over, so it could not answer this on its own.
  **The operator attests on 2026-10-27 that the dashboard password is machine-generated**, which is not
  verifiable from the hash and is recorded as attestation, not as evidence. It changes the reading above:
  OWASP's cost floor exists to make offline cracking of a *guessable* input expensive, and a
  full-entropy input needs no such help — 2^14/p=1 is sub-floor and still irrelevant, because there is
  nothing to enumerate. The username is six characters and not one of `admin`/`root`/`dashboard`, which
  removes the attacker's first guess and nothing else.

### Why no rate limiter — decided, not deferred

The rule written below was resolved the same day it was written: the password is machine-generated, so
**no `rateLimit` middleware is being added to this host.**

A `rateLimit` middleware would have bought two things:

- **Guessing headroom — now worth nothing.** Unthrottled, one source IP can try as many passwords as it
  can send packets for, but against a machine-generated password none of them land. The scrypt cost
  above caps the attempt rate at the pod anyway.
- **Pod headroom — still unthrottled, and that is the residual.** 16 MiB plus CPU per failed attempt is
  a way to starve the pod that runs the agent gateway alongside the dashboard, and nothing limits it.
  Accepted: it is an availability hit on one console, the same unauthenticated-request cost every other
  public host here already carries, and the liveness probe on `:9119` is a `tcpSocket` that would keep
  succeeding right up until the container restarted for something else.

What it would have cost: Traefik's limiter is per source IP and counts **every** request including the
console's static assets, so a threshold tight enough to slow a guesser is a threshold that locks the
operator out of the page they need in order to log in — and that failure presents as an outage, not a
lockout, with the pod healthy and every gate green.

The rule stays, for the next host that is not behind a machine-generated credential: **add the middleware
if the password is human-chosen** — measure one console page load first and set the burst above it.

### Live check after merge, 2026-10-27 — run, and passing

Merged as `3d780ea`. Flux applied it to the `apps` stage (`lastAppliedRevision: main@sha1:3d780ea…`,
`ReconciliationSucceeded`) and the `Ingress` came up with the annotation intact:

```console
$ kubectl --context titan -n apps get ingress investing-agent -o jsonpath='{.metadata.annotations}'
{"traefik.ingress.kubernetes.io/router.entrypoints":"websecure"}
```

Then the pair that proves the add behaved:

```console
$ curl -o /dev/null -w '%{http_code}\n' http://investing-agent.titan.arrieta.eu/
404
$ curl -o /dev/null -w '%{http_code}\n' https://investing-agent.titan.arrieta.eu/
302
```

- **The 404 on `http://` is the fix working** — refused, not redirected, as claimed. A 200 there is the
  signature of the annotation having been deleted.
- **The 302 on `https://` is the gate, not a fault**: `location: /login?next=%2F`, and following it
  reaches a 200 login page. Before merge both hosts answered 404 — Traefik's own, no router matching the
  host yet — which is why the pair has to be run after the sync rather than before.
- **TLS is the wildcard**: `CN=titan.arrieta.eu`, notBefore 2026-10-03, notAfter 2027-01-01, served
  through the reflected `titan-tls`. The handshake is the whole proof — the check ran as the read-only
  `k8s-reader` identity, which is Forbidden on Secrets by design, so nothing here read the certificate.

**The gate is a form login, not HTTP Basic.** The Secret's keys are named `HERMES_DASHBOARD_BASIC_AUTH_*`,
but `GET /` answers 302 to `/login?next=%2F` and no response carries `WWW-Authenticate`; what
`HERMES_DASHBOARD_BASIC_AUTH_SECRET` signs is the session cookie that follows a successful login. The
manifest said "basic auth" and now says login. The posture is unchanged — and a session cookie loose in
cleartext is a worse outcome than one basic-auth header, which is one more reason the entrypoint pin is
the line that matters.

### Re-check after the 2026-10-28 gate — baseline taken, post-merge check run and passing

The pair above is the 2026-10-27 state and stays as measured. The gate changes what `https://` has to
answer, so the baseline was re-taken immediately before PR #192 landed, which makes the post-merge
check a comparison rather than a hope:

```console
$ kubectl --context titan -n apps get ingress investing-agent -o jsonpath='{.metadata.annotations}'
{"traefik.ingress.kubernetes.io/router.entrypoints":"websecure"}
$ kubectl --context titan -n apps get middleware teslamate-auth -o jsonpath='{.spec.forwardAuth.address}'
http://authentik-server.auth.svc.cluster.local/outpost.goauthentik.io/auth/traefik
$ curl -o /dev/null -w '%{http_code}\n' https://investing-agent.titan.arrieta.eu/
302
$ curl -o /dev/null -w '%{http_code}\n' http://investing-agent.titan.arrieta.eu/
404
```

All four measured 2026-10-28 as the read-only `k8s-reader` identity, before the change. Merged as
`a9c0831`; the `apps` stage reached `Ready=ReconciliationSucceeded rev=main@sha1:a9c0831…` roughly 90
seconds later, behind `infra` → `certificates` → `databases`. The `DependencyNotReady` cascade along
the way is propagation, not a stall, and it is why this check has to wait for the sync rather than the
merge. Then:

```console
$ kubectl --context titan -n apps get ingress investing-agent -o jsonpath='{.metadata.annotations}'
{"traefik.ingress.kubernetes.io/router.entrypoints":"websecure","traefik.ingress.kubernetes.io/router.middlewares":"apps-teslamate-auth@kubernetescrd"}
$ curl -o /dev/null -w '%{http_code} %{redirect_url}\n' https://investing-agent.titan.arrieta.eu/
302 https://auth.titan.arrieta.eu/application/o/authorize/?client_id=…&state=<jwt>   # elided
$ curl -o /dev/null -w '%{http_code}\n' http://investing-agent.titan.arrieta.eu/
404
```

- **The gate is live, and the predicted hop was wrong.** The 302 does not land on
  `auth.titan.arrieta.eu/outpost.goauthentik.io/start?rd=…`, which is what this section and the
  manifest both claimed before merge. It goes to `auth.titan.arrieta.eu/application/o/authorize/`, and
  the target host rides inside the signed `state` JWT as
  `"redirect":"https://investing-agent.titan.arrieta.eu/"`. Judge it by the authority in `Location`:
  `auth.titan.arrieta.eu` is gated, `investing-agent.titan.arrieta.eu/login` is not.
- **Three wrong answers, three faults** — a 302 still landing on `/login` is the middleware not
  firing, a 200 is the host serving strangers, and a 404 with a clean Traefik log is authentik
  refusing a host its provider no longer matches. Nothing alerts on any of this, so it is a check
  someone has to run.

**Not set, deliberately left that way:** no HSTS header on this host. Harmless while `http://` answers 404
— a downgrade needs an active attacker, not a stale bookmark — so a nit, not a finding.

`make dry-run` on this branch now builds and accepts `50-apps` with **74** objects (the Ingress is
one of them); the stage builds to **77** on main as of 2026-10-27, three up from main-side merges rather
than anything here. Nothing about the add is covered by an offline gate that did not exist before — the
`Ingress` is a core type and `crd-check`'s scope is custom resources only, and the live API server
was the one that accepted it (the same gate that caught the `data:`/base64 Secret defect). Two
Ingress fields sit outside every gate here and are worth naming: `spec.tls[].secretName` —
`secret-refs` walks workloads, never Ingresses, so a typo'd `titan-tls` builds green and surfaces as
a TLS handshake failure — and the Traefik annotations above, which nothing reads. Both values are
correct as written; both would fail as a runtime symptom, not a red build.
