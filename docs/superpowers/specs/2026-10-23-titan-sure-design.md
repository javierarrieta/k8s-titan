# Sure on titan — design

- **Status:** proposed, not implemented
- **Date:** 2026-10-23
- **App:** [Sure](https://github.com/we-promise/sure) — community fork of the archived
  Maybe Finance. Chart `sure-0.7.6-alpha.9`, image `ghcr.io/we-promise/sure`.
- **Predecessor:** this started as a throwaway spike in k8s-casa
  (`scripts/sure-trial/`), which is superseded by this design and should be deleted
  rather than merged.

## 1. Why titan, and why at all

The household's Firefly III instance in casa went unused for over a year because
importing from Revolut and Trade Republic was a manual upload each time. The
candidate replacement is judged on removing that friction, not on looks.

Sure has one thing Firefly III does not, and it is the reason this spec exists:
**built-in LLM auto-categorization** (`app/models/provider/openai/auto_categorizer.rb`,
`docs/hosting/ai.md`). Firefly III's equivalent request
([firefly-iii#9753](https://github.com/firefly-iii/firefly-iii/issues/9753)) is
`closed / not_planned`; its answer is a deterministic rules engine, which is
maintenance — the exact thing that went stale.

titan rather than casa because titan has the pieces a multi-week trial needs and
casa does not: a CloudNativePG operator with a shared `Cluster` and a
`ScheduledBackup`, authentik, cert-manager with the `titan.arrieta.eu` wildcard,
Reflector, Reloader, and a WireGuard mesh that advertises `192.168.0.0/24`.

## 2. Placement, per the written rules

**Namespace: its own — `sure`.** §3.1 of
`2026-10-19-titan-app-scale-out-design.md` admits to the shared `apps` namespace
only workloads with "roughly one or two pods, no database of their own, no public
hostname of their own, no credentials beyond what they read from their own config".
Sure is web + worker + Redis + Postgres, with its own Secret set and its own public
hostname. It fails on four counts. Entry added to
`apply/00-bootstrap/namespaces.yaml`.

**Stage: stays in `apply/50-apps/`.** Per the 2026-10-21 amendment, §3.1 decides
namespace and not stage; a stage is bought by object count, edit frequency and
freeze cost. Sure's bulk is a `HelmRelease`, and the spec's own reasoning kept
coder and open-webui in `apps` for that reason — bad `values` fail the
HelmRelease on their own instead of failing the unit. One `HelmRelease`, one
`HelmRepository`, two CNPG objects and a Redis Deployment is not Tesla's 27
hand-written objects.

**Files:**

```
apply/50-apps/sure/sure-db.yaml        # CNPG Database + DatabaseRole, namespace `databases`
apply/50-apps/sure/sure.yaml           # HelmRepository + HelmRelease + Redis + PVC + Ingress
apply/50-apps/auth/blueprints-sure.yaml # authentik OIDC client, mounted by the authentik HR
apply/10-secrets/sure-secrets.yaml     # SOPS
apply/10-secrets/sure-db-credentials.yaml
```

plus one line each in `apply/50-apps/kustomization.yaml` (both files — the
`coder-db.yaml` story), `namespaces.yaml`, `reloader.namespaces`
(`apply/20-infra/reloader/reloader.yaml`, `watchGlobally: false` so the annotation
is inert without it), and the Reflector destination for `titan-tls`.

## 3. Chart configuration decisions

| decision | value | why |
| --- | --- | --- |
| `cnpg.enabled` | `false` | The chart defaults to installing the CloudNativePG operator and its own `Cluster`. titan already runs both. Sure joins the shared `postgres` Cluster as a `Database` + `DatabaseRole`, which is how mealie, open-webui, coder and authentik all live, and it inherits the existing `ScheduledBackup` for free. |
| `redisOperator.enabled` | `false` | No Redis operator on titan. Redis is a plain Deployment in `sure`, the same shape `apply/60-tesla/redis.yaml` uses. |
| `redisSimple.enabled` | `false` | Its service name and password key are chart-derived; an explicit Deployment and `REDIS_URL` is checkable, a guess is not. |
| `DATABASE_URL` / `REDIS_URL` | via `rails.extraEnvVars` with `secretKeyRef` | Setting those two keys in `rails.extraEnv` is what makes `templates/_env.tpl` skip the chart-computed URLs. `extraEnvVars` takes full `EnvVar` objects, so the password stays in a Secret instead of in a committed values block. |
| `image.tag` | `0.7.6-alpha.9`, pinned | Never `stable`. This is pre-1.0 software: `v0.7.6-alpha.9` was published the day this was written and there are 769 open issues. Upgrades are a deliberate commit, not a tag that moves. |
| `migrations.strategy` | `job` | Helm pre-upgrade hook, so a schema migration that fails fails the release loudly instead of crash-looping the web pod. |
| PVC | `local-path-retain` | Same reasoning as mealie: `Retain` is the only deletion mitigation here, and it is a deletion mitigation, **not** a backup. |

## 4. What is backed up and what is not

Postgres (users, accounts, transactions, categories, the OIDC identity) is in the
shared Cluster and therefore ships base backups and WAL on the existing schedule.
The PVC at `/rails/storage` is not — the generic PV stream is still deferred.
Named exposure, same as mealie's recipe photos.

## 5. Sign-in

Public host `sure.titan.arrieta.eu`, **no forward-auth middleware**, in-app OIDC
against authentik — the mealie and open-webui pattern, and for the same recorded
reason: the app holds the client secret and needs the code exchange to complete in
its own process, and a proxy provider would mean editing the Tesla-owned outpost
blueprint that owns that provider list.

Sure reads `OIDC_CLIENT_ID`, `OIDC_CLIENT_SECRET`, `OIDC_ISSUER` from the chart's
secret block and `OIDC_REDIRECT_URI` from env (present in `.env.example`, absent
from the chart's `secret.values`, so it goes in `rails.extraEnv`).

### 5.1 Two independent doors, and only one of them is ONBOARDING_STATE

This section originally said "deploy open, create the account by hand, close it".
That was wrong, and reading the source is what showed it. Sure has **two
independent ways to acquire an account** and `ONBOARDING_STATE` governs only the
first:

| door | governed by | enforced at |
| --- | --- | --- |
| local email+password registration page | `ONBOARDING_STATE` | `registrations_controller.rb:119-121` |
| SSO account creation (JIT) | `AUTH_JIT_MODE`, `ALLOWED_OIDC_DOMAINS` | `oidc_accounts_controller.rb:24,119` — never reads `onboarding_state` |

`AUTH_JIT_MODE` defaults to `create_and_link` (`config/auth.yml`): an authentik
identity with no Sure account is sent to `oidc_accounts#new_user` and creates
itself. So the correct configuration is `ONBOARDING_STATE: "closed"` from the very
first reconcile — the first account comes from SSO, authentik-authenticated from
birth, and the instance is never reachable in a state where the first visitor wins
it. Upstream's docker.md step 5a assumes a local first account; with OIDC
configured that step is unnecessary.

**What actually bounds JIT is authentik's enrolment policy, not the domain list.**
`ALLOWED_OIDC_DOMAINS` is `gmail.com` here, which filters nothing; and empty means
*all* domains, not none (`AuthConfig.allowed_oidc_domain?` returns true when the
list is empty). Evidence from this repo: the Google source deliberately has **no
`enrollment_flow`** (`authentik/blueprints-google.yaml:8,85` — "unknown Google
identities are denied"), so Google cannot self-enrol. The **default authentik
registration flow is not declared anywhere in this tree**, so whether username and
password self-signup is open at `auth.titan.arrieta.eu` is **unverified** — check it
in the admin UI. If it is open, the fix is `AUTH_JIT_MODE=link_only`, not a wider
allowlist.

`make sure-check` gates both doors with explicit acknowledgement annotations, so a
permissive setting is always a reviewed statement rather than a default that
shipped.

Still unverified: whether the first JIT-created user becomes a super admin, and
whether `AUTH_LOCAL_ADMIN_OVERRIDE_ENABLED` would leave a way in if authentik were
down. Local login is therefore left at its default rather than relying on a
break-glass path that has not been proven.

Related: check whether Sure honours `email_verified` the way mealie v3.21.0 had to
(mealie's comment records that release "turned on the email_verified requirement
the OIDC block has to answer"). If Sure requires it, the authentik provider must
be configured to release the claim or sign-in fails with an error pointing
somewhere else.

## 6. LLM auto-categorization

`OPENAI_URI_BASE=http://192.168.0.29:8731/v1` — casa's halogen endpoint on llm01,
reachable from titan pods because the mesh advertises `192.168.0.0/24`. Precedent
that this works: grafana's datasource (`grafana-datasources.yaml:7`), promtail
reaching `192.168.0.42` ("Measured from a titan pod: HTTPS 200"), and opencloud
talking to `192.168.0.6:9000`.

`OPENAI_URI_BASE` **must include `/v1`** — it is passed straight to the ruby-openai
client as `uri_base` (`app/models/provider/openai.rb:85`). With a custom base,
`supports_responses_endpoint?` defaults to false, so it calls
`/v1/chat/completions`, which is what the endpoint serves. Verified: `/v1/models`
returns `halogen-qwen3.8-flash-next` (`max_model_len` 262144), `/health` 200, and
`response_format: json_object` returns valid JSON.

### 6.1 The reasoning-model problem

`halogen-qwen3.8-flash-next` emits `reasoning_content` before `content`, and
reasoning tokens are charged against `max_tokens`. Measured: `max_tokens: 16`
returned `finish_reason: length` with **`content: ""`**. In an auto-categorizer
that is indistinguishable from "nothing to do" — a silent no-op that looks healthy.

The operator can disable reasoning per request (`chat_template_kwargs:
{"enable_thinking": false}`, or `reasoning: {"effort":"none"}`, or
`thinking: {"type":"disabled"}` — all measured working; `chat_template_kwargs:
{"thinking": false}` errors). **Sure cannot send it**: its provider builds client
options from `access_token` / `uri_base` / `model` only, and the sole per-request
escape in `.env.example` is `OPENAI_EXTRA_HEADERS`, which is headers, not body.
So until upstream grows an `extra_body`, the mitigation is budget and batch size:

```
LLM_MAX_RESPONSE_TOKENS=2048      # default is far smaller; reasoning eats it
LLM_MAX_ITEMS_PER_CALL=10         # Sure's default is 25
LLM_JSON_MODE=auto
OPENAI_REQUEST_TIMEOUT=120
AI_RESPONSE_TIMEOUT=180
ASSISTANT_MAX_TOOL_CALL_ITERATIONS=3
OPENAI_SUPPORTS_PDF_PROCESSING=false
```

Upstream issue worth filing: an `OPENAI_EXTRA_BODY` env. That would make the
endpoint's own switch usable and cut latency and tokens at once.

### 6.2 Unverified before this can go live

**Whether casa's firewall admits tcp/8731 from mesh sources.** Every existing
precedent is 443 or 9000. The operator attests open-webui on titan already talks to
this endpoint, which is good evidence — but the repo cannot confirm it: open-webui's
Secret carries no base URL (checked 2026-10-23), because open-webui keeps model
configuration in its own Postgres, set in the UI. So it stays attested-not-measured.
The command that settles it, once titan is reachable:

```
kubectl --context titan -n sure exec deploy/sure-web -- \
  curl -sf --max-time 10 http://192.168.0.29:8731/v1/models
```

If it fails, the options are opening 8731 to the mesh CIDR in casa's firewall, or
running the trial without AI categorization — which removes the entire reason for
the trial, so it must be settled before the trial is called a result.

## 10. Found while implementing (2026-10-23), all verified by rendering or by the cluster

1. **The chart does not wire `OPENAI_ACCESS_TOKEN` when `existingSecret` is set.**
   `rails.secret.values` lists it (and `OIDC_CLIENT_ID` / `_SECRET` / `_ISSUER`), but
   with `existingSecret` the chart emits only `SECRET_KEY_BASE` and the three
   `ACTIVE_RECORD_ENCRYPTION_*` keys as `secretKeyRef` entries — measured by
   rendering 0.7.6-alpha.9. Anything else the app needs from the Secret must be
   named in `rails.extraEnvVars` or it silently never reaches the pod. This is the
   chart's version of "a gate that passes vacuously": the Secret has the key, the
   pod does not, and AI stays off at `health=ok`.
2. **`make db-url-check` cannot see Sure.** `tools/db-url-check.py` walks a
   HelmRelease env named `*PG_CONNECTION_URL` (coder) and a Deployment's
   `DATABASE_URL` (open-webui). Sure is a HelmRelease carrying `DATABASE_URL` —
   neither shape — so the gate reports zero references and passes. Its own docstring
   names this as the one failure mode it must never have. A `sure-check` target is
   **required before merge**, not a nice-to-have.
3. **`dependsOn` was not available.** The `Database` is applied by the same `apps`
   Kustomization as the HelmRelease, and there is no HelmRelease named `postgres`
   to depend on (the Cluster is a plain CNPG object; verified with
   `kubectl --context titan get helmrelease -A`). coder has the identical race and
   solves it with install retries; Sure does the same.
4. **Reloader reads the pod template here.** The chart exposes only
   `web.podAnnotations` / `worker.podAnnotations`, no workload-metadata annotation,
   so the `reloader.stakater.com/auto` annotation goes there — an annotation on the
   HelmRelease itself would have been inert, which is the fifth instance of the
   defect `reloader.yaml` records.

**Unrelated live finding on titan, noticed while checking CNPG:**
`databaserole.coder` reports
`secrets "coder-db-credentials" is forbidden: User
"system:serviceaccount:databases:postgres" cannot get resource "secrets" in API group
"" in the namespace "databases"`. The role shows `APPLIED true` with that message.
mealie, open-webui, authentik and teslamate show no such message. Pre-existing,
nothing to do with Sure, and worth a separate look — a role that cannot read its own
password Secret is a rotation waiting to fail.

## 7. Gates

`make check` on titan is far stricter than casa's. New targets mirroring
`mealie-check`:

- `sure-check` — ties `BASE_URL`/`OIDC_REDIRECT_URI` in the HelmRelease values to
  the redirect URIs in `blueprints-sure.yaml`, the failure class mealie's check
  exists to catch.
- `db-url-check` already exists and must pass with the composed `DATABASE_URL`.
- `namespace-check`, `kustomize-listing`, `secrets-placement`, `crd-check`,
  `leak-check` all apply unchanged.

## 8. Acceptance

1. `make check` green.
2. HelmRelease `Ready`, web and worker pods Running, migrate Job completed.
3. `sure.titan.arrieta.eu` reachable, sign-in via authentik, `/account/sign_up`
   closed after step 5.1.
4. A Revolut CSV (multi-currency, containing an FX conversion) imports into one
   account per currency wallet without duplicating the conversion.
5. Auto-categorization returns categories for ~50 real rows through halogen, and
   the log shows non-empty `content` — not the empty-content failure in §6.1.
6. `kubectl --context titan -n databases get backup` shows Sure's database
   included in the next scheduled run.

## 9. Explicitly out of scope

- Replacing Firefly III. Nothing in casa is deleted until Sure survives a few weeks.
- Trade Republic account connection, until the Enable Banking application exists.
- Multi-user. One human, one account.
- The casa spike directory, which is deleted rather than maintained.
