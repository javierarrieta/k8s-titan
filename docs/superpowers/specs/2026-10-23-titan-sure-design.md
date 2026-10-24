# Sure on titan — design

- **Status:** implemented in `apply/`, **not yet applied to the cluster**. Reviewed 2026-10-24 against
  the rendered chart; the corrections from that review are recorded in §10 items 9-12.
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
apply/50-apps/sure/sure-db.yaml                # CNPG Database + DatabaseRole, namespace `databases`
apply/50-apps/sure/sure.yaml                   # HelmRepository + HelmRelease + Redis + PVC
apply/10-secrets/authentik-sure-blueprint.yaml # authentik OIDC client; a Secret, mounted by the
                                               # authentik HelmRelease. NOT a ConfigMap under auth/ —
                                               # it carries the client_secret.
apply/10-secrets/sure-secrets.yaml             # SOPS
apply/10-secrets/sure-db-credentials.yaml      # SOPS
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
| `DATABASE_URL` / `REDIS_URL` | via `rails.extraEnvVars` with `secretKeyRef` | `extraEnvVars` takes full `EnvVar` objects, so the password stays in a Secret instead of in a committed values block. **Not** because naming them suppresses the chart-computed URLs — an earlier row here claimed that and was wrong. `templates/_env.tpl` skips its own URL only when the key is in the `rails.extraEnv` *map* (`hasKey`); the chart computes nothing here because `cnpg.cluster.enabled` and both Redis paths are off. Verified by rendering: 28 env entries, no duplicates. `sure-check` pins all three of those flags off. |
| `image.tag` | `0.7.6-alpha.9`, pinned | Never `stable`. This is pre-1.0 software: `v0.7.6-alpha.9` was published the day this was written and there are 769 open issues. Upgrades are a deliberate commit, not a tag that moves. Pinned twice — chart `version` and `image.tag` — so `sure-check` fails if the two drift. |
| `migrations.strategy` | `job` | **post-install/post-upgrade, not pre-upgrade** (`templates/migrate-job.yaml:9`, and the chart README says so in words). A failed migration fails the release loudly, but it does not stop the new web pod serving a schema it has not migrated. `initContainer` closes that window for the web pod only, and adds a first-boot dependency on a rake task never observed running here; see §10 item 9. |
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
identities are denied"), so Google cannot self-enrol.

**The default registration flow was then measured closed, from outside.** Same
server, same path shape, same anonymous client, 2026-10-23:

| request | result |
| --- | --- |
| `GET /if/flow/default-authentication-flow/` | **200** |
| `GET /if/flow/default-user-settings-flow/` | **200** |
| `GET /if/flow/default-registration-flow/` | **404** |
| `GET /flows/-/default/authentication/` | 302 → `/if/flow/default-authentication-flow/` |
| `GET /flows/-/default/registration/` | **404** |

The two 200s are the control: the endpoint works and unauthenticated flow pages are
reachable here, so the registration 404 is a statement about that flow and not
about the probe. `/if/flow/<slug>/` 404s for deleted, not-visible and not-public
alike, which is a real limitation of the method — but all three mean the same thing
to an anonymous visitor, and an anonymous visitor is the only audience a
registration flow has.

So the JIT door is passable only by identities authentik already holds accounts for,
which is what the `sso-jit-boundary` annotation asserts. If authentik enrolment ever
opens, the fix is `AUTH_JIT_MODE=link_only`, not a wider allowlist.

Note what did **not** work as a probe, so nobody repeats it: `/api/v3/flows/executor/…`
returns 404 for every slug from outside, including `default-authentication-flow`, so
the API paths are not usable evidence from here. `/if/flow/<slug>/` is.

`make sure-check` gates both doors with explicit acknowledgement annotations, so a
permissive setting is always a reviewed statement rather than a default that
shipped.

**Is the first JIT-created user a super admin? Yes, by design — source-verified, no live login
required.** `User.role_for_new_family_creator` returns `User.exists? ? fallback_role : :super_admin`,
guarded by `pg_advisory_xact_lock(FIRST_USER_ROLE_LOCK_KEY)` so concurrent first signups cannot both
win, and the JIT path calls it at `oidc_accounts_controller.rb:159`. So the first SSO-provisioned
account owns the instance and everyone after it is `admin` unless mapped otherwise.

**Group mapping from authentik exists, and is deliberately not used here.**
`oidc_identity.rb#apply_role_mapping!` reads `provider_config[:settings][:role_mapping]`, walks
`super_admin > admin > member > guest` first-match-wins, supports `*`, and runs from
`sync_user_attributes!` on *every* login. Three reasons it is not worth wiring for one human:

- **No env var.** `role_mapping` lives in the provider config's `settings`; for the env-driven default
  provider that config is `config/auth.yml` baked into the image. The DB path exists
  (`SsoProvider#to_omniauth_config` passes `settings:` through, with an admin UI), but
  `ProviderLoader.load_providers` only consults the DB when `FeatureFlags.db_sso_providers?` is on.
- **It is not a revocation mechanism.** If no mapped group matches, the function returns without
  touching the role. Removing someone from the authentik group does not demote them unless they match
  a lower mapped role — the healthy state and the broken state look identical again.
- **Authentik must release the claim**, via a scope/property mapping that emits `groups`; this repo
  already learned that with mealie, where `property_mappings` had to include the profile scope or the
  claim simply was not in the token.

**Break-glass if authentik is down** remains unverified: `AUTH_LOCAL_ADMIN_OVERRIDE_ENABLED` depends on
being a super admin, and that status has not been exercised. Local login is therefore left at Sure's
default rather than relying on an unproven escape hatch.

**`email_verified` — answered 2026-10-24: Sure does not enforce it.** mealie v3.21.0 had to be told to
stop requiring it (its comment records that release "turned on the email_verified requirement the OIDC
block has to answer"), and authentik's managed email mapping deliberately returns
`"email_verified": false`. Sure needs neither a `CODER_OIDC_IGNORE_EMAIL_VERIFIED`-style opt-out nor a
custom mapping: grepping `email_verified` across `app/controllers/` found no consumer, and the JIT path
keys on `auth.info.email`. **Honest limit:** that is a grep of the code that handles the callback, not a
proof about the whole application, and the exchange has never been exercised live (§10 item 5). If the
first real login fails on a claim, this is the first place to look.

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

### 6.2 Reachability of the endpoint from titan — settled, by a chain

**tcp/8731 from mesh sources is open.** Proven transitively rather than by a probe:
open-webui runs on titan, and its admin settings point at this endpoint with models
responding (confirmed by the operator, 2026-10-23). open-webui's traffic therefore
already crosses the mesh to `192.168.0.29:8731`, so casa's firewall admits it from
mesh sources — no new firewall work is needed for Sure.

Why this could not be settled from git, recorded so nobody re-derives it: open-webui
keeps model configuration in its own Postgres, set in the UI, so its Secret carries
no base URL (`sops --decrypt apply/10-secrets/open-webui-secrets.yaml | grep -i
openai` returns only `DATABASE_URL`, checked 2026-10-23). The fact lives in a
database, not in a manifest, which is exactly the class of thing a repository cannot
audit.

Direct check, if it is ever doubted:

```
kubectl --context titan -n sure exec deploy/sure-web -- \
  curl -sf --max-time 10 http://192.168.0.29:8731/v1/models
```

## 10. Found while implementing (2026-10-23), all verified by rendering or by the cluster

*(Numbered 10 and sitting between §6.2 and §7 because it was appended after the first review; the
number is referenced from `apply/50-apps/sure/sure.yaml` and from the commit messages, so it stays.)*

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
5. **The OIDC callback path is source-verified, and reading the wrong field would have got it right by
   accident.** `config/initializers/omniauth.rb` calls `provider :openid_connect, oidc_options`, and
   OmniAuth mounts at `/auth/<strategy>/callback` — the segment is the **strategy symbol**, not the
   provider `name`. In `config/auth.yml` both happen to be `openid_connect`, so checking only the name
   would have produced the correct path for the wrong reason and broken the day someone added a second
   provider under a different name.

   The same initializer hides a silent failure worth knowing before debugging a missing SSO button: if
   `OIDC_ISSUER` / `CLIENT_ID` / `SECRET` are blank, `Oidc::ProviderOptionsBuilder` returns nothing, the
   initializer logs `Skipping OIDC provider 'openid_connect' - missing required configuration` and
   carries on. The app boots healthy with password login only. That is precisely what the
   `existingSecret` gap in item 1 would have caused had those three not been named in `extraEnvVars`
   — and `make sure-check` requires them.

6. **The first draft of the blueprint was not appliable, and the gate passed it.** Found 2026-10-24, four
   defects in one file, each of which fails at authentik apply time or at first login rather than at any
   check that existed:

   | defect | why it is fatal |
   | --- | --- |
   | `property_mapping:` singular, `model: authentik_sources_ldap.ldappropertymapping` | an `oauth2provider` takes `property_mappings` (plural) of `authentik_providers_oauth2.scopemapping`. The LDAP model belongs to LDAP sources. This is also the field that releases the `email` claim the JIT path keys on |
   | `fk:` used for `signing_key`, `authorization_flow`, `property_mapping` | `fk` resolves an `id:` inside the same blueprint (`v1/importer.py:175-197`, populated at `:441`); cross-object references must be `!Find`/`!Get`. A foreign `fk` reaches the serializer verbatim and fails as a UUID error |
   | no `signing_key` | authentik then signs the `id_token` HS256 with the `client_secret` (`providers/oauth2/models.py:358-359`). Every pre-login check passes; the first real login dies at token verification |
   | no `invalidation_flow`, no `issuer_mode` | logout does not propagate, and `OIDC_ISSUER` names the per-provider URL so `issuer_mode: per_provider` is load-bearing, not cosmetic |

   The coder blueprint already documented the `!Find` lesson and the invented-`default-scopes` failure,
   which is what made the pattern visible once the file was actually read. `make sure-check` now refuses
   each of the four, plus a missing `scope-email` mapping and `OIDC_CLIENT_SECRET` drift between the two
   files that hold it — seven mutations, each verified to fail the gate with its own message.

7. **Nothing here invalidates authentik sessions, and nothing should.** There is no `invalidate` key in
   this blueprint, nor in mealie's or coder's. A contrary claim was made on 2026-10-24 and retracted the
   same day after the file was read; it is recorded so nobody re-adds the key on the strength of it. The
   `reloader` annotation restarts the authentik Deployment when the blueprint Secret changes, and a
   restart does not end sessions — the cookie signing key lives in the database, not in the pod.

8. **The Sure client secret was rotated before first apply.** A decrypted copy reached a session
   transcript while the blueprint was being read during review. Nothing had used the credential, so the
   rotation cost nothing; `OIDC_CLIENT_SECRET` in `sure-secrets.yaml` and `client_secret` in the blueprint
   are the same value and the gate now fails if they diverge.

9. **`migrations.strategy: job` is a post-install/post-upgrade hook, and the first version of this spec
   and of `sure.yaml` both called it pre-upgrade.** `templates/migrate-job.yaml:9` hardcodes
   `helm.sh/hook: post-install,post-upgrade`; the chart README says so in words. The claimed protection
   — "a schema migration that fails fails the release instead of crash-looping the web pod" — is
   inverted: the new pods are applied first and the migration runs afterwards. Kept, deliberately, and
   the comment now says what actually happens: `initContainer` closes the window for the web pod only
   (`worker-deployment.yaml` has no initContainer path at all) and adds a first-boot dependency on
   `rake db:pending_migrations`, a task this image has never been observed running here. Related: the
   chart's `until pg_isready` loop does **not** absorb the CNPG role race — `pg_isready` answers
   "accepting connections" even when the role or password is wrong.

10. **`install.remediation.retries: 1` was not the coder mechanism the comment credited.** Flux's default
    install remediation is `uninstall`, so that line meant *tear the release down and reinstall it
    immediately* — retrying the role race with no delay and taking the pods down while it did. coder uses
    `install.strategy: {name: RetryOnFailure, retryInterval: 5m}` (`apply/50-apps/coder/coder.yaml:48-51`)
    and this now does too.

11. **The hand-written Redis was root and open, and nothing could see it.** The chart does not render it,
    so no gate looked: no `securityContext` at all (the redis image sets no `User`, so it ran as root —
    `apply/60-tesla/redis.yaml:28-38` is the file that documents exactly this trap for the same image
    digest this file cites), and no `--requirepass`. With no `NetworkPolicy` anywhere in this tree, an
    open Redis is writable from every pod in the cluster, and a Sidekiq queue anyone can enqueue to is an
    execution primitive running as Sure's user against Sure's database. Now `runAsNonRoot` 999/1000 with
    `drop: [ALL]`, `--requirepass` from a new `REDIS_PASSWORD` key, and three gate checks: the URL names
    the Service, the URL and the password key agree, and the pod reloads on rotation — because one Secret
    has three readers and a rotation that restarts only the Rails pods leaves Redis requiring the old
    password while the app presents the new one.

12. **`sure-check` had four holes of its own, each measured by mutating the tree and watching it stay
    green.** `REDIS_URL` was never checked at all; the reloader and Reflector checks were substring
    searches (`- sure-not-real` satisfied one, a comment naming the annotation satisfied the other); and
    two malformed inputs raised a traceback instead of reporting (`entries:` missing, `podAnnotations:`
    present-but-null). All four are fixed, the two list checks now parse the objects instead of grepping
    text, and the gate additionally pins `cnpg.cluster.enabled`, `redisOperator.managed.enabled`,
    `migrations.strategy`, and chart-version-vs-image-tag drift. The lesson is the same one §10 item 6
    records for the blueprint: a gate written from a reading of the chart, never run against a broken
    tree, is a gate that reports what its author expected.

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

- `sure-check` — the gate that can see inside a `HelmRelease`. It ties the OIDC client across the
  blueprint Secret, its mount on the authentik `HelmRelease`, and Sure's own copy in `sure-secrets`;
  `OIDC_REDIRECT_URI` to the blueprint's `redirect_uris` and `OIDC_ISSUER` to `issuer_mode`;
  `DATABASE_URL` to CNPG's copy of the password and to the `Database`/`DatabaseRole`; `REDIS_URL` to
  the hand-written `sure-redis` Service and to the `REDIS_PASSWORD` that Service requires; and the
  chart defaults that fail silently at `health=ok`. It does **not** involve `BASE_URL` — an earlier
  draft of this section said so, and nothing in the app, the chart or the gate uses that variable.
- `db-url-check` cannot see Sure at all (see §10 item 2), which is the reason `sure-check` exists.
- `namespace-check`, `kustomize-listing`, `secrets-placement`, `crd-check`,
  `leak-check` all apply unchanged.

## 8. Acceptance

1. `make check` green.
2. HelmRelease `Ready`, web and worker pods Running, migrate Job completed. Note the Job is a
   **post**-install hook (§3), so it runs after the pods exist: `Ready` before the Job completes is
   normal, not a sign the hook is missing.
3. `sure.titan.arrieta.eu` reachable, sign-in via authentik end to end — the token exchange, not just
   the redirect. `/account/sign_up` is closed from the first reconcile (§5.1); confirm it, do not
   assume it.
4. The LLM endpoint answers **from a sure pod**, not by inference from open-webui:
   `kubectl --context titan -n sure exec deploy/sure-web -- curl -sf --max-time 10 http://192.168.0.29:8731/v1/models`.
   §6.2 argues reachability by a chain; this is the measurement.
5. A Revolut CSV (multi-currency, containing an FX conversion) imports into one
   account per currency wallet without duplicating the conversion.
6. Auto-categorization returns categories for ~50 real rows through halogen, and
   the log shows non-empty `content` — not the empty-content failure in §6.1.
7. `kubectl --context titan -n databases get backup` shows Sure's database
   included in the next scheduled run.
8. Redis actually requires the password: `kubectl -n sure exec deploy/sure-redis -- redis-cli ping`
   returns `NOAUTH Authentication required` with no credentials, and `PONG` with them.

## 9. Explicitly out of scope

- Replacing Firefly III. Nothing in casa is deleted until Sure survives a few weeks.
- Trade Republic account connection, until the Enable Banking application exists.
- Multi-user. One human, one account.
- The casa spike directory, which is deleted rather than maintained.
