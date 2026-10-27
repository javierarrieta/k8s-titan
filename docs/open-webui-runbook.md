# open-webui runbook

Design and evidence: `docs/superpowers/specs/2026-10-20-titan-open-webui-design.md`.
Live objects: `apply/50-apps/open-webui/` (namespace `open-webui`), credentials in
`apply/10-secrets/open-webui-secrets.yaml` and `apply/10-secrets/open-webui-db-credentials.yaml`,
OIDC client in `authentik/blueprints-open-webui.yaml` rendered to
`apply/10-secrets/authentik-open-webui-blueprint.yaml`.

## 1. Where the data actually is

Postgres database `open_webui` in the shared CNPG `Cluster` `postgres` (namespace `databases`) holds
users, roles, chats, prompts, knowledge metadata, API keys, the model connection and the encrypted
OAuth session tokens. That is the half covered by `apply/30-databases/`'s `ScheduledBackup` and by the
restore and point-in-time drills recorded in `docs/authentik-runbook.md` §2 (its "Point-in-time —
recorded" subsection is the PITR proof).

The PVC `open-webui-data` (`local-path-retain`, so deletion keeps the PV) holds `uploads/` and
`vector_db/` — chroma is the default vector store in the standard image, not pgvector. The vector
index is derived and rebuildable from the Postgres rows. **Uploads are neither in a backup nor
rebuildable.** The generic PV stream is still deferred, so nothing ships that directory off the node.
Say so plainly rather than assuming the database backup covers the app.

## 2. `WEBUI_SECRET_KEY` — the one not to rotate casually

It signs session JWTs and is the default for `OAUTH_SESSION_TOKEN_ENCRYPTION_KEY`, so rotating it
logs everyone out and orphans every stored OAuth access/refresh token. Its only copy is
`apply/10-secrets/open-webui-secrets.yaml`.

The reason it is set explicitly at all: v0.12.3 refuses to boot without it (`env.py:786`), and
`start.sh` otherwise generates one into `/app/backend/.webui_secret_key` — inside the container
layer, so it is new on every pod and every stored token is undecryptable after a restart. k8s-casa's
open-webui still has that bug; its own log says so (`InvalidToken`). The proof this half works is
§6's last line: delete the pod, keep the session.

Rotate it only deliberately, and expect to re-consent every OAuth integration afterwards.

## 3. Who may sign in, and as what

authentik decides; there is no local password form (`ENABLE_LOGIN_FORM=false`).

- The first authentik user to sign in ever becomes open-webui **admin**, whatever the env says
  (`utils/oauth.py:1598-1607` at v0.12.3). Do that on purpose and record it here:
  - first admin: (fill in at first sign-in — who, and when)
- `ENABLE_OAUTH_ROLE_MANAGEMENT=true` with `OAUTH_ROLES_CLAIM=groups`: membership of
  `authentik Admins` → open-webui admin (the same group Grafana maps,
  `apply/60-tesla/grafana.yaml`); `OAUTH_ALLOWED_ROLES=*` → any other authentik user becomes `user`.
- Anyone outside those groups gets a **403, not a pending account**. With role management on, a
  missing or unmatched `groups` claim denies rather than falling back — which is also why the
  provider's `property_mappings` must keep the `profile` scope: that mapping is what emits `groups`.
  A login page that looks healthy while every non-admin is locked out is the symptom;
  `make open-webui-oidc-check` is the gate.

## 4. The callback path, and narrowing the blueprint

`authentik/blueprints-open-webui.yaml` registers **both** `/oauth/oidc/callback` and
`/oauth/oidc/login/callback`, each `matching_mode: strict`, because open-webui computes its own
redirect URI with `request.url_for('oauth_login_callback', provider='oidc')` over two same-name
routes (`main.py:2932-2933`) and which one `url_for` returns is an inference from decorator order,
not a measurement. The segment is `oidc` — the registry key at `config.py:2812` — not `authentik`,
which is only the display label.

After the first real login, record which path appeared and delete the other:

- observed on the wire: (fill in)

Then re-run `scripts/setup-open-webui-secrets.sh` with `FORCE=1` (it re-mints everything, so instead
prefer editing both files by hand if you want to keep the same client), and run
`make open-webui-oidc-check`, which enforces the pair.

## 5. Forcing the blueprint

Mounting is not applying. The worker discovers mounted blueprints at startup and hourly; to apply
now, use the authentik UI or the same code path the periodic task uses:

```fish
kubectl -n auth exec deploy/authentik-worker -- ak apply_blueprint \
  /blueprints/mounted/secret-authentik-open-webui-blueprint/open-webui.yaml
```

Two cautions copied forward from `docs/authentik-runbook.md` §5, because they are traps and not
background: that `exec` needs an **admin context** (the read-only `k8s-reader` identity is `Forbidden`
on `pods/exec`), and **a blueprint validation failure prints the client secret to stdout** — do not
paste the output anywhere until it has been read. §5 is also the record of what a
committed-but-never-mounted blueprint looks like: nothing. The worker's
`secret.reloader.stakater.com/reload` annotation lists this blueprint so a merge restarts the worker
instead of waiting up to an hour — that annotation is why PR #42's fix looked like it had not landed.

## 6. Verifying a change

`make check` offline. Then, against the live cluster (read-only identity where it can reach —
`docs/agent-read-access.md`):

```sh
kubectl -n databases get database open-webui,databaserole open-webui -o wide
kubectl -n open-webui get pod,deploy,pvc
curl -sI https://open-webui.titan.arrieta.eu       # 200, not a TLS error
```

`kubectl -n open-webui get secret titan-tls` is **not** on that list on purpose: the read-only
`k8s-reader` identity cannot read Secrets anywhere (AGENTS.md, and re-measured on the first deploy —
`Forbidden` listing `secrets` in `open-webui`). The `curl` above is the read-only substitute: if
Reflector had not reflected the wildcard, Traefik would be serving a TLS error instead of a 200. Read
the Secret itself with an admin context if you need to confirm its notBefore.

Then the four things only a human can check: admin login lands, a non-admin login lands, a
non-member is refused, and `kubectl -n open-webui delete pod` leaves the session and the stored
OAuth token intact — that last one is the proof §2 is real rather than theoretical.

### First deploy — recorded 2026-10-20

PR #96 merged as `9f886dd`. Observed with the read-only identity, not inferred:

- All seven Flux stages reached `main@sha1:9f886dd` Ready, including `secrets` — which is the proof
  the three new sops files are encrypted to `titan-k8s`. Wrong recipients fail that stage and freeze
  everything downstream of it.
- `Database open-webui`: `applied: true`. CNPG `Cluster postgres`: `Ready=True`,
  `ContinuousArchiving=True`, `LastBackupSucceeded=True`.
- PVC `open-webui-data` Bound on `local-path-retain`; Deployment 1/1 Available; pod Running, 0
  restarts.
- `curl -sI https://open-webui.titan.arrieta.eu` → `HTTP/2 200`, so `titan-tls` was reflected.
- Log showed Alembic running the migrations through `242a2047eae0, Update chat table` with no
  `error`, `traceback`, `permission denied` or `InvalidToken`.

Not covered by any of that: the four human checks above, and forcing the blueprint. A green deploy
proves the app starts and answers, not that a person can sign in — the OIDC client was mounted and
not yet applied at that point (§5).

## 6a. Web search (SearXNG) — and why the env vars may not be enough

Web search runs through the SearXNG in `apply/50-apps/searxng/searxng.yaml`: one pod, namespace
`apps`, ClusterIP only, no Ingress and no hostname. open-webui asks it questions at
`http://searxng.apps.svc.cluster.local/search` — see that file's header for why the FQDN is
required and why `formats: [html, json]` is the line that makes the whole thing work.

**The trap.** `ENABLE_WEB_SEARCH`, `WEB_SEARCH_ENGINE` and `SEARXNG_QUERY_URL` are *persistent*
config. At startup open-webui seeds every known key into the `config` table and, from then on, the
row wins over the environment: `Config.seed_defaults` (`backend/open_webui/models/config.py:248-271`
at v0.12.3) inserts a key **only when it is absent**, and `Config.get` prefers the row. So merging
the env vars into the Deployment does not, by itself, turn search on for an instance that has already
booted once — which is every instance of this deployment after 2026-10-20.

Check which world you are in before touching anything — but **not over HTTP.** There is no
unauthenticated endpoint that reports this, and the two obvious-looking ones are traps. Measured
2026-10-27 on this deployment:

- `GET /config` returns the **SPA's HTML**, not JSON. It is the frontend route, not a config API.
- `GET /api/config` is JSON and returns only `status`, `name`, `version`, `default_locale`, `i18n`,
  `oauth` and `features`. There is no `web_search` key in it at all.
- The endpoints that do expose it — `/api/config/export`, `/api/config/namespace/{ns}` — are
  `get_admin_user`-gated (`backend/open_webui/routers/configs.py:120-139`).

So the direct check is the database, with an admin context:

```sh
# read the rows first; this is the measurement, the DELETE further down is the fix
PRIMARY=$(kubectl -n databases get pods -l cnpg.io/cluster=postgres,cnpg.io/instanceRole=primary -o jsonpath='{.items[0].metadata.name}')
echo "primary = $PRIMARY"
kubectl -n databases exec -i "$PRIMARY" -- psql -U postgres -d open_webui -c \
  "SELECT key, value FROM config WHERE key LIKE 'web.search.%' ORDER BY key;"
```

Two things that were measured rather than assumed, because the obvious forms of both are wrong. The
primary is found by the `cnpg.io/instanceRole=primary` label, **not** by guessing `postgres-1` and
**not** by `.status.targetPrimaryInstance` — that field does not exist in this CNPG version and
returns an empty string, which reads as a broken command rather than a wrong one. The live fields are
`.status.currentPrimary` and `.status.targetPrimary`. And `-i`, not `-it`: a TTY is not needed and
`-t` complains when there is not one.

If `web.search.enable` reads `true` and `web.search.searxng_query_url` holds the in-cluster URL, git is
the source of truth and there is nothing to do. If it reads `false`, the seeded rows are in charge.

**A read-only hint, short of the database.** `seed_defaults` logs `Seeded %d new config defaults` only
when it actually inserted something. On the 2026-10-27 deploy that added these env vars the line is
absent from the pod log — nothing was missing, so every `web.search.*` row already existed, so the new
env values were never written. Be clear about what that proves: it is an inference from the code plus
the log, not a read of the row. The `SELECT` above is the measurement.

Two ways out, if the rows are in charge:

1. **Delete the rows and let the environment re-seed** (preferred — git stays authoritative):

   ```sh
   # admin context. $PRIMARY is the pod the SELECT block above resolved.
   kubectl -n databases exec -i "$PRIMARY" -- psql -U postgres -d open_webui -c \
     "DELETE FROM config WHERE key IN ('web.search.enable','web.search.engine','web.search.searxng_query_url','web.search.result_count');"
   kubectl -n open-webui delete pod -l app=open-webui
   ```

   `-U postgres` and not the app role on purpose: the open-webui `DatabaseRole` is deliberately not a
   superuser (`apply/50-apps/open-webui/open-webui-db.yaml:34`), and the `config` table belongs to the
   app user, so either works — but the CNPG superuser is the one that does not depend on how the role
   was granted. The restart re-seeds from the env vars. Confirm with the `SELECT` above, or by running
   a search in the UI.

2. **Set it in Admin → Settings → Web Search.** Faster, and it works, but the value then lives in
   Postgres and not in git, and every later edit there silently outranks the manifest. If this path is
   taken, record it here.

Either way: **a later click in the Admin UI re-takes precedence over git.** A panel that says searxng
and a manifest that says searxng can still disagree about `WEB_SEARCH_RESULT_COUNT`, and the panel is
the one in charge.

Proving the engine itself answers, from inside the cluster (needs an admin context — the read-only
identity cannot `exec`):

```sh
kubectl -n apps exec deploy/searxng -- sh -c \
  'wget -qO- "http://localhost:8080/search?q=titan&format=json" | head -c 200'
```

JSON back means `formats` took; a 403 means it did not. Empty `results` with a 200 means SearXNG is
fine and the upstream engines are the problem — check egress with
`kubectl -n apps exec deploy/searxng -- sh -c 'wget -qO- https://html.duckduckgo.com/ | head -c 80'`
and look at `/engine_descriptions.json` plus the pod log for engine suspensions.

### Bring-up — recorded 2026-10-27

PR #172 merged as `7d3adb0`. Observed with the read-only `k8s-reader` identity, not inferred:

- Stage `apps` reached `main@sha1:7d3adb0` `Ready=True` at 11:52:10Z; all eight stages stayed Ready.
- `Deployment searxng` 1/1 Available; pod Running, **0 restarts**. That restart count is the proof
  `SEARXNG_SECRET` worked: `searx/webapp.py:1380` calls `sys.exit(1)` when the key is still
  `ultrasecretkey`, so a missing override crash-loops the pod rather than warning.
- Log: `Starting granian`, `Listening at: http://[::]:8080`, `Started worker-1`. Four things in that
  log are expected and should not be mistaken for breakage: two `not owned by "searxng:searxng"` /
  `Got "root:searxng"` warnings (`fsGroup` sets the group, never the owner, and `FORCE_OWNERSHIP:
  "false"` makes the entrypoint warn instead of trying to chown as non-root); `missing config file:
  /etc/searxng/limiter.toml` and `X-Forwarded-For nor X-Real-IP header is set!`, both from the bot
  detection that `limiter: false` leaves inert; and `ahmia` / `torch` failing to register, which are
  hidden-service engines with no tor here.
- `Deployment open-webui` rolled at 11:52:13, pod Ready, 0 restarts, and the live pod spec carries all
  four search env vars.

Not proven at the moment of that deploy, and none of it reachable to `k8s-reader` — `auth can-i create
pods/exec` and `auth can-i create pods/portforward` both answer `no`, so neither a `kubectl exec` probe
nor a port-forward is available to an agent. All three were closed later the same day, by the operator
with an admin context:

- The `SELECT` showed the trap exactly as predicted: `web.search.enable = false`, `engine = ""`,
  `searxng_query_url = ""`, `result_count = 3` — 67 rows of `web.search.*`, four of them lying about
  what git says.
- The `DELETE` of those four keys plus a pod delete, and the proof it took is a log line, not a guess:
  `12:08:18 open_webui.models.config:seed_defaults:273 - Seeded 4 new config defaults`. Four keys
  missing, four inserted from the environment. Pod Ready, 0 restarts, `/health` true.
- A search from the UI returned results and **fetched two of the result URLs**. That closes the
  `format=json` question, the in-cluster FQDN, and titan's egress to an upstream engine in one action
  — and it also disproved a claim made in the PR that shipped this. See below.

**The claim that was wrong: page retrieval is not off.** The PR said leaving `WEB_LOADER_ENGINE` unset
meant open-webui would return "titles and snippets only" and would not fetch arbitrary URLs from the
pod. It does fetch them. `get_web_loader` (`backend/open_webui/retrieval/web/utils.py:1181-1183` at
v0.12.3) maps `''` to `SafeWebBaseLoader` — unset is the default fetching path, not a disabled one —
and `web.search.bypass_web_loader` is `false` in the live table, which the `SELECT` above shows. What
`WEB_LOADER_ENGINE` chooses is the *renderer*, not whether to fetch. The two fetched URLs were the
proof. The key that would actually turn retrieval off is `BYPASS_WEB_SEARCH_WEB_LOADER=true`; the
SSRF guard in front of the loader is `safe_validate_urls` (same file, line 1159), not the absence of
an engine. The manifest comment now says so.

## 7. Not proven / not done

- `uploads/` is unbacked (§1). No plan yet; the PV's `Retain` is a deletion mitigation, not a backup.
- ~~The non-superuser `DatabaseRole` is an argument from absence~~ — **closed 2026-10-20**: the
  migrations ran against `open_webui` on the live cluster with no elevation (§6). If a future
  migration needs more, the pod fails at Alembic and the fix is a deliberate `superuser: true` with
  its own note — not a silent widening. That reasoning still stands for versions after v0.12.3:
  the default vector store is what makes the role sufficient, and a default that changes reopens it.
- Inference is not wired: no llama.cpp endpoint is configured. It is reachable from the LAN; that has
  not been proven from inside a pod, so nobody should promise it works until something answers.
- Web search works: measured end to end on 2026-10-27 (§6a), including the row-delete the persistent
  config needed. What is still open is tuning — no engine has been enabled, disabled or given a key, and
  result quality on a default engine set has not been looked at. And remember the standing hazard: a
  click in Admin → Settings → Web Search silently outranks git from then on.
- The `local-path-retain` PVC has never been restored on this cluster.
