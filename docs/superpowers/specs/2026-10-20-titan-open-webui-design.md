# titan — open-webui, with authentik OIDC and its data in CNPG

Status: **accepted design, not yet implemented**. The implementation plan is a separate document;
this one decides the shape and records what was measured rather than assumed.

Written 2026-10-20. The request was "open-webui in titan, same config as in `../k8s-casa`, use OIDC
auth". "Same config as casa" turned out to be the part that needed the most arguing with, because
casa's instance carries two defects that are invisible in casa and expensive to inherit: no
`WEBUI_SECRET_KEY` (§6) and a data directory nothing backs up (§8.4). Six decisions were put to the
operator one at a time; each is recorded below with the alternative that was declined.

## 1. What this is for

A second, independent Open WebUI instance on titan. It does **not** replace casa's instance and
imports nothing from it: no data migration, no freeze of casa, no shared credential. casa's
open-webui keeps running with its own SQLite file and its own authentik client on
`open-webui.home.arrieta.eu`.

Success looks like: `https://open-webui.titan.arrieta.eu` answers, signs in through
`auth.titan.arrieta.eu` with no local password form, gives the first person through the door the
`admin` role, gives every other authentik user `user`, keeps its chats and users inside the
Postgres cluster that this cluster already backs up, and survives a pod restart without invalidating
stored OAuth tokens — which is the thing casa cannot currently do (§6).

## 2. What was measured

Everything below was read from the live clusters, from the pinned image's own source at tag
`v0.12.3`, or from this repository. Nothing here is a guess carried forward.

| | |
|---|---|
| `ghcr.io/open-webui/open-webui:v0.12.3` | what casa pins **and** the current upstream latest (`GET /repos/open-webui/open-webui/tags`) — so parity and current are the same thing |
| Postgres support in that image | `backend/requirements.txt` carries `psycopg[binary]==3.3.4` and `psycopg2-binary==2.9.12`; `internal/db.py:251-257` rewrites `postgresql://` → `postgresql+psycopg://` for the async engine and passes the URL through otherwise. `DATABASE_URL` default is `sqlite:///{DATA_DIR}/webui.db` (`env.py:271`). No extra driver, no `-slim` image needed |
| The PVC is still required with Postgres | `config.py:180` `UPLOAD_DIR = DATA_DIR / 'uploads'`; `config.py:512` `CHROMA_DATA_PATH = f'{DATA_DIR}/vector_db'`; `config.py:509` `VECTOR_DB` defaults to `chroma` in the standard image |
| `WEBUI_SECRET_KEY` is a hard requirement | `env.py:786` raises `SystemExit` when auth is on and the key is empty. `backend/start.sh` then auto-generates one into `${WEBUI_SECRET_KEY_FILE:-.webui_secret_key}` — a **relative** path, after `cd "$SCRIPT_DIR"` → `/app/backend/.webui_secret_key`, on the container's writable layer, **not** on the PVC, which mounts at `/app/backend/data` |
| …and what that costs | casa's live log: `ERROR open_webui.models.oauth_sessions:_decrypt_token:101 - Error decrypting tokens: InvalidToken`. The same key is `OAUTH_SESSION_TOKEN_ENCRYPTION_KEY` (`env.py:881`) and `OAUTH_CLIENT_INFO_ENCRYPTION_KEY` (`:879`), and it signs the JWTs |
| The image runs as root | `Dockerfile:24` `ARG UID=0`, `:137` `chown -R $UID:$GID /app`. Not a non-root image, so a `restricted` PSA label would be warn-only noise |
| First user is admin, unconditionally | `utils/oauth.py:1598-1607`: one user in the table → `admin`, re-asserted on every login; zero users → default role, promotion post-insert |
| Second user is `pending` unless role management is on | `config.py:2660` `ENABLE_OAUTH_ROLE_MANAGEMENT` defaults **false**; `config.py:1748` `DEFAULT_USER_ROLE` defaults to **`pending`** |
| Role management denies, it does not downgrade | `utils/oauth.py:1645-1670`: if the roles claim is present and matches neither `OAUTH_ALLOWED_ROLES` nor `OAUTH_ADMIN_ROLES`, the login gets a hard `403`. `OAUTH_ALLOWED_ROLES` defaults to `user,admin` (`config.py:2681`) |
| The env OIDC provider's key is `oidc`, not the display name | `config.py:2812` registers `OAUTH_PROVIDERS['oidc']`; `OAUTH_PROVIDER_NAME` (`:2639`, default `SSO`) is only the label. So the callback path segment is `oidc` — casa's `OAUTH_PROVIDER_NAME=authentik` never appears in a URL |
| …and the callback path is derived, not configured | `main.py:2932-2933` binds two routes to one handler name (`/oauth/{provider}/login/callback` and the legacy `/oauth/{provider}/callback`); `utils/oauth.py:1919` uses `request.url_for('oauth_login_callback', provider=…)` unless the discovery document supplies a `redirect_uri`, which authentik's does not |
| titan can reach the LAN from a pod | promtail on titan pushes to `loki.local.arrieta.eu`, which resolves to `192.168.0.42` (`docs/titan-logs-loki.md`, live pod) |
| CNPG services | `postgres-r` / `postgres-ro` / `postgres-rw` in `databases`, no bare `postgres`, no `Pooler` object. One `Cluster`, healthy |
| Node headroom | one node, allocatable 12 CPU / 131793368Ki |
| `*.titan.arrieta.eu` | public wildcard owned by `../public-dns-tf`; a new host needs no DNS record and no new `Certificate` |

## 3. Decisions

| # | decision | declined alternative, and why it matters |
|---|---|---|
| D1 | **Fresh instance.** No import from casa | Replacing casa would have meant freezing its pod and moving a SQLite file into Postgres, and casa's instance is in daily use. Declined by the operator, not inferred |
| D2 | **Data in CNPG Postgres**, not SQLite on a PVC | This cluster backs up the Postgres cluster and nothing else (`apply/30-databases/postgres-backup.yaml`: base backups plus continuous WAL to S3; PITR drilled, `docs/authentik-runbook.md`). SQLite on `local-path-retain` survives `kubectl delete pvc` and not the disk. Cost accepted: one password in two namespaces, and a gate to keep them together (§5.4) |
| D3 | **In-app OIDC only.** No authentik forward-auth on this host | Forward-auth would mean editing `apply/50-apps/auth/tesla-outpost-blueprint.yaml` — a Tesla file that *owns* the embedded outpost's provider list — for a non-Tesla app, and would put a Traefik middleware in the path of open-webui's streaming and socket.io traffic. The host is public either way, like `coder.` and `auth.` today |
| D4 | **Model backend configured in the admin UI**, not in git | casa's connection (`halogen`, an OpenAI-compatible llama.cpp endpoint at `192.168.0.29:8001`) lives in the app database, not in a manifest. With D2 that connection now lands inside the backed-up cluster. An external API key in `apply/10-secrets/` was declined: more git surface, a rotation to remember, and a cost centre behind a public hostname |
| D5 | **Roles come from authentik groups**, following the Grafana precedent | `apply/60-tesla/grafana.yaml:143` already maps `authentik Admins` → admin off the `groups` claim, and its comment records why: the group is authentik's own bootstrap default, so membership stays managed in one place instead of becoming a fourth copy of a list. Casa's parity config would have made the admin whoever clicked first and everyone else `pending` |
| D6 | **Coder-shaped layout**: own namespace, shared `apps` stage | Not its own numbered stage, even though §3.2 of `2026-10-19-titan-app-scale-out-design.md` reads literally as qualifying it (own Secret set, own database). Accepted cost, stated plainly in §9: open-webui's manifests are hand-written, so a malformed field fails the `apps` Kustomization atomically and freezes authentik's updates until the next commit |

## 4. Layout

```
apply/00-bootstrap/namespaces.yaml              + Namespace open-webui
apply/00-bootstrap/kustomization.yaml           unchanged (no new stage — D6)
apply/40-certificates/titan-wildcard.yaml       reflector allow-list += open-webui  (both annotations)
apply/20-infra/reloader/reloader.yaml           reloader.namespaces += open-webui
apply/50-apps/kustomization.yaml                + open-webui/open-webui-db.yaml, open-webui/open-webui.yaml
apply/50-apps/open-webui/open-webui-db.yaml     CNPG Database + DatabaseRole, namespace `databases`
apply/50-apps/open-webui/open-webui.yaml        PVC + Deployment + Service + Ingress, namespace `open-webui`
apply/10-secrets/open-webui-db-credentials.yaml basic-auth, namespace `databases`
apply/10-secrets/open-webui-secrets.yaml        namespace `open-webui`
apply/10-secrets/authentik-open-webui-blueprint.yaml  rendered, namespace `auth`
apply/10-secrets/kustomization.yaml             all three listed
authentik/blueprints-open-webui.yaml            reviewed template, placeholders, plaintext
scripts/setup-open-webui-secrets.sh             mints every value, writes all three sops files
tools/open-webui-oidc-check.py                  the four-way agreement gate
tools/db-url-check.py                           widened: Deployments, not only HelmReleases
Makefile                                        + open-webui-oidc-check, added to `check`
apply/50-apps/auth/authentik.yaml               blueprints.secrets += authentik-open-webui-blueprint
docs/open-webui-runbook.md                      what is in Postgres vs on the PVC, and the rules
AGENTS.md                                       layout line and gate list
```

**No PSA label on the namespace.** coder and monitoring carry
`pod-security.kubernetes.io/warn: restricted`; open-webui does not get it, because the image runs as
uid 0 (§2) and a warn-only label on a workload that can never satisfy it is a signal that reads
better than it is. If a non-root image build is ever wanted, the label goes on in the same change.

**The namespace is `open-webui` and the stage is `apps`.** Per D6 this is coder's shape: the
namespace isolates the Secrets and the RBAC surface, the stage stays shared. Nothing moves, so
`prune: true` has nothing to garbage-collect and the three-commit prune dance in §3.2 of the
scale-out spec does not apply to a brand-new namespace.

## 5. The database

### 5.1 `Database` and `DatabaseRole`

`apply/50-apps/open-webui/open-webui-db.yaml`, both objects in namespace `databases`, because a CNPG
`Database` must share a namespace with its `Cluster` — the same reason `coder/coder-db.yaml` and
`60-tesla/teslamate-db.yaml` are where they are.

```yaml
kind: Database      # metadata.name: open-webui   spec.name: open_webui   spec.owner: open_webui
                    # spec.cluster: postgres
kind: DatabaseRole  # metadata.name: open-webui   spec.name: open_webui   spec.login: true
                    # spec.passwordSecret: open-webui-db-credentials
```

The Kubernetes object names carry the hyphen like every other object in the namespace; the Postgres
identifiers inside them do not.

- **`open_webui` with an underscore, not `open-webui`.** A hyphen makes the identifier quoted in
  Postgres, and every place that interpolates it becomes a bug. The namespace and the hostname keep
  the hyphen; the role and the database do not.
- **`login: true` is required and silent when missing** — CNPG creates the role `NOLOGIN` by
  default, which is the recorded authentik lesson repeated in `coder-db.yaml`.
- **Not `superuser: true`.** TeslaMate needs elevation for `earthdistance`, and its file says so with
  the migration list that forces it. open-webui's default vector store is chroma on the filesystem,
  not `pgvector`, so nothing here should need an extension. This is the one claim in this document
  that is argued from absence rather than from a list of migrations, so the plan carries it as a
  live check: if a migration needs more, the pod fails at startup, loudly, and the fix is a
  deliberate `superuser: true` with its own note — not a silent widening.

### 5.2 The two Secrets

`open-webui-db-credentials` — `kubernetes.io/basic-auth`, namespace `databases`, `username:
open_webui`, `password`, and the `cnpg.io/reload` label on **this** Secret rather than on the
`DatabaseRole`, where it would do nothing.

`open-webui-secrets` — namespace `open-webui`, four keys:

| key | |
|---|---|
| `DATABASE_URL` | `postgresql://open_webui:<pw>@postgres-rw.databases.svc.cluster.local:5432/open_webui` — `postgres-rw` because CNPG publishes `-r`/`-ro`/`-rw` and there is no bare `postgres` service; no `?sslmode=` because CNPG accepts plaintext client connections, which is how authentik already connects |
| `WEBUI_SECRET_KEY` | long random, see §6 |
| `OAUTH_CLIENT_ID` | the pair authentik also holds (§7) |
| `OAUTH_CLIENT_SECRET` | ditto |

### 5.3 What is in Postgres, and what is not

Postgres holds the canonical records: users, roles, chats, prompts, knowledge metadata, API keys,
the admin's connection settings (D4) and the encrypted OAuth session tokens. The PVC holds
`uploads/` and `vector_db/`. The vector index is derived and rebuildable; **uploads are not**, and
they are in neither backup. That is a named exposure (§9), not an oversight.

### 5.4 The gate, and why the existing one does not cover it

`tools/db-url-check.py` exists for exactly this shape — one password, two objects, silent split —
but it walks `HelmRelease` env named `*PG_CONNECTION_URL` under `values.coder.env`. open-webui is a
plain `Deployment` with `DATABASE_URL`, so it is invisible to that finder and the gate would report
zero references and pass vacuously. **Widen the finder to `Deployment` containers' `env` entries
whose name is `DATABASE_URL` and whose `secretKeyRef` resolves**, keeping the existing comparison
(URL user == `DatabaseRole` name, URL password == that role's `passwordSecret` password). TeslaMate
has the same blind spot today and is covered only by its setup script's own cross-check; widening the
tool is the reason to do it here rather than write a fourth near-duplicate checker.

## 6. `WEBUI_SECRET_KEY` — the deliberate deviation from casa

Casa sets no `WEBUI_SECRET_KEY`. v0.12.3 would refuse to boot, so `start.sh` generates one into
`/app/backend/.webui_secret_key`, which is container-local: **the key is recreated on every pod
start.** It signs the JWTs and it is the key that encrypts the stored OAuth session tokens, so
every restart orphans every token already in the table — which is precisely what casa's log reports
and what a user experiences as "my model connection went missing after an upgrade".

Titan sets `WEBUI_SECRET_KEY` in `open-webui-secrets`, generated once by
`scripts/setup-open-webui-oidc.sh` alongside the client pair, and the runbook states the rule:
**rotating it invalidates every session and every stored OAuth token**, so it is rotated only
deliberately, and never as a side effect of touching the OIDC client.

This is a deviation from "same config as casa" and it is justified by an observed failure, not by
taste. casa should get the same fix — as its own change, with its own decision about the tokens it
has already orphaned. It is not bundled here.

## 7. authentik OIDC

The pattern is the one coder, Google and Grafana already use, for the reason recorded in
`docs/authentik-runbook.md` §5: authentik ships no CRDs, so a blueprint is the only declarative
path, and a blueprint that is not mounted is indistinguishable from one that was never written.

### 7.1 The template — `authentik/blueprints-open-webui.yaml`

Plaintext, reviewed, with `${OPEN_WEBUI_OIDC_CLIENT_ID}` and `${OPEN_WEBUI_OIDC_CLIENT_SECRET}`
placeholders, and one `Application` entry beside the provider — the provider alone is not enough,
which is the 404-for-every-host lesson in `tesla-outpost-blueprint.yaml`.

- `oauth2provider` named `open-webui`: `client_type: confidential`, grant types
  `authorization_code` + `refresh_token`, `issuer_mode: per_provider`,
  `sub_mode: hashed_user_id`, `authorization_flow: default-provider-authorization-implicit-consent`,
  `invalidation_flow: default-invalidation-flow`, `signing_key: goauthentik.io/crypto/jwt-managed`,
  and the four scope mappings `openid` / `email` / `profile` / `offline_access`.
- **`profile` is load-bearing, not decoration.** The `groups` claim that D5's role mapping reads only
  exists because the default profile scope mapping emits it. Drop the scope and every non-admin
  login 403s — with role management on, an absent claim is a denial, not a downgrade.
- `application` slug `open-webui`, `meta_launch_url: https://open-webui.titan.arrieta.eu/`.
- **Not added to the embedded outpost's `providers` list.** That list is proxy-only and
  `validate_providers` dispatches on provider type; the Grafana blueprint records the same line and
  for the same reason.
- Endpoints are read from the live discovery document, as the Grafana template records:
  `authorize`/`token`/`userinfo` are global paths with no slug, `issuer` and `jwks` are per-provider.

### 7.2 The redirect URI — the one thing this document cannot settle from source

`utils/oauth.py:1919` computes it with `request.url_for('oauth_login_callback', provider='oidc')`
because authentik's discovery document carries no `redirect_uri`. `main.py:2932-2933` binds two
routes to that one handler name, so the value depends on which Starlette finds first:

```
https://open-webui.titan.arrieta.eu/oauth/oidc/callback          (legacy route, registered first)
https://open-webui.titan.arrieta.eu/oauth/oidc/login/callback    (current route)
```

Note the path segment is **`oidc`** — the registry key at `config.py:2812` — and not `authentik`,
which is only the display name from `OAUTH_PROVIDER_NAME`. Getting this wrong is a
`redirect_uri mismatch` from authentik that reads like a client-secret problem.

The blueprint therefore registers **both** paths, each `matching_mode: strict` (a prefix match on a
redirect URI is a redirect bypass). The plan's first live login records which one actually appears
on the wire, and the blueprint is then narrowed to that one in the same branch. Registering two
same-host paths is not a loosening; leaving one unproven and un-narrowed would be sloppy, which is
why the narrowing is a step and not a note.

### 7.3 The script — `scripts/setup-open-webui-secrets.sh`

Named like `setup-coder-secrets.sh` rather than like `setup-grafana-oidc.sh`, because it does more
than the OIDC pair: it mints the client id, the client secret, the database password and
`WEBUI_SECRET_KEY`, and writes **all three** sops files —
`apply/10-secrets/authentik-open-webui-blueprint.yaml` (namespace `auth`, the rendered template),
`apply/10-secrets/open-webui-db-credentials.yaml` (namespace `databases`, `kubernetes.io/basic-auth`)
and `apply/10-secrets/open-webui-secrets.yaml` (namespace `open-webui`, the full four-key Secret of
§5.2). Writing the whole Secret rather than patching two keys into it is what keeps `DATABASE_URL`
and `open-webui-db-credentials` minted from one value in one process — the split the widened
`db-url-check` (§5.4) then proves from the tree instead of trusting.

Everything else is `setup-grafana-oidc.sh`'s shape for the same reasons: sops-encrypt with
`--encrypt --in-place` on a git-ignored staging path under `apply/10-secrets/` (sops picks its
recipients from the file's own path), print only a truncated SHA-256 per file, refuse to overwrite
any existing file without `FORCE=1`, and trap to remove the staging files whatever fails. Bash,
run-not-read: the operator's login shell is fish and has no heredocs.

### 7.4 The gate — `tools/open-webui-oidc-check.py`

`make open-webui-oidc-check`, added to `check` beside `grafana-oidc-check`, comparing four things
that can disagree silently: the reviewed template, the rendered blueprint authentik applies, the
app's own copy of the client pair, and the redirect URIs in the blueprint against `WEBUI_URL`. It
reads sops-encrypted values, so it is a local gate like `validate`, `db-url-check` and
`oidc-check` — a gate that skips is a gate that lies.

### 7.5 App env

Casa's set, unchanged in value and re-pointed at titan:

```
DATA_DIR=/app/backend/data
OAUTH_PROVIDER_NAME=authentik
OPENID_PROVIDER_URL=https://auth.titan.arrieta.eu/application/o/open-webui/.well-known/openid-configuration
WEBUI_URL=https://open-webui.titan.arrieta.eu
ENABLE_OAUTH_SIGNUP=true
ENABLE_LOGIN_FORM=false
OAUTH_MERGE_ACCOUNTS_BY_EMAIL=true
OAUTH_SCOPES=openid email profile
OAUTH_SUB_CLAIM=sub
OAUTH_TOKEN_ENDPOINT_AUTH_METHOD=client_secret_basic
OPENID_END_SESSION_ENDPOINT=https://auth.titan.arrieta.eu/application/o/open-webui/end-session/
ENABLE_WEBUI_LOG=true
ENABLE_OAUTH_ID_TOKEN_COOKIE=true
OAUTH_UPDATE_PICTURE_ON_LOGIN=true
OAUTH_UPDATE_NAME_ON_LOGIN=true
```

plus D5's four:

```
ENABLE_OAUTH_ROLE_MANAGEMENT=true
OAUTH_ROLES_CLAIM=groups
OAUTH_ADMIN_ROLES=authentik Admins
OAUTH_ALLOWED_ROLES=*
```

`OAUTH_ALLOWED_ROLES=*` means any authentik-authenticated user gets `user`; the alternative —
leaving the default `user,admin` — 403s everyone who is not in an authentik group literally named
`user` or `admin`, which is nobody. That is the trap this line exists to defuse and the comment in
the manifest says so. `offline_access` is granted by the provider but not requested by the app, as
in casa; nothing here depends on a refresh token, and inventing a scope change would be a change of
behaviour dressed as parity.

## 8. The workload

### 8.1 Deployment

`open-webui` in namespace `open-webui`, `strategy: Recreate` (the PVC is `ReadWriteOnce`), image
`ghcr.io/open-webui/open-webui:v0.12.3`, `envFrom` the Secret, `reloader.stakater.com/auto: "true"`.
Requests `100m`/`500Mi`, limits `1` CPU/`2Gi` — casa's numbers, against a node with 12 CPU and
~125 GiB allocatable. Casa's `nodeSelector: kubernetes.io/arch: amd64` is dropped: one amd64 node,
and no other manifest in this repo pins arch.

### 8.2 Reloader — the annotation is not enough

`apply/20-infra/reloader/reloader.yaml` runs `watchGlobally: false` with an explicit
`namespaces:` list (`coder`, `auth`, `monitoring`, plus the release namespace `apps`). Reloader does
not look outside that list, so `reloader.stakater.com/auto` on a Deployment in `open-webui` is
**inert** until `open-webui` is added there — the exact defect that file documents for promtail, and
the reason a Secret rotation would otherwise appear to be ignored by a pod that was never watching.

### 8.3 Ingress and TLS

`ingressClassName: traefik`, host `open-webui.titan.arrieta.eu`, `secretName: titan-tls`. `titan-tls`
is produced in `certificates` by the wildcard and reaches a namespace only if that namespace is in
the `secretTemplate` annotations on `apply/40-certificates/titan-wildcard.yaml` — currently
`apps,auth` in **both** `reflection-allowed-namespaces` and `reflection-auto-namespaces`. Both
lists get `open-webui`; editing one is the half-done version of this change. No new `Certificate`,
no ACME order, no DNS record.

### 8.4 Storage

PVC `open-webui-data`, 10 Gi, `storageClassName: local-path-retain`. Not `local-path`: `Retain` is
the only deletion mitigation this cluster has for a PVC, and it is a deletion mitigation, not a
backup (§5.3). 10 Gi matches casa's request; `local-path` is thin, so the number is a ceiling and
not an allocation.

## 9. Not proven, and accepted

- **A malformed manifest in `apps` freezes authentik's updates.** D6. The scale-out spec's own
  precedent (Tesla's 27 hand-written objects got `60-tesla`) points the other way; the operator
  chose the shared stage anyway. `make dry-run` is the gate that would have caught the class of error
  and it needs an admin context that does not exist here by decision, so the offline gates and the
  `crd-check` against `vendor/cnpg-crds/` are the whole mitigation for the two new CNPG objects.
- **Uploads are not backed up.** §5.3. Chats, users and settings are; uploaded files are not, and
  they are not rebuildable.
- **The non-superuser role is argued from absence.** §5.1. Proven or disproven at first startup.
- **Which callback path is live is not settled from source.** §7.2. Both are registered; the plan
  narrows it after a real login.
- **`192.168.0.29:8001` is reachable from the LAN, not proven reachable from a titan pod.** The
  promtail→Loki path proves the `/24` is routable from a pod; the specific host and port are not
  covered by anything in this repo, and `k8s-reader` cannot `pods/exec`. Either the operator
  confirms it or the first admin UI connection attempt is the test.
- **`make release-secrets` cannot vouch for these Secrets.** It reads `HelmRelease` values;
  open-webui is a `Deployment`. Same honest limit as teslamate, and the reason `secrets-placement`
  and `open-webui-oidc-check` exist.
- **No network segmentation.** `apps` has no `NetworkPolicy` and k3s enforces none
  (scale-out spec §4). open-webui reaching Postgres over a flat network is the cluster's standing
  condition, not a new one.

## 10. Verification

Offline, on the laptop, before any push:

```
git add -A
make check            # leak-check, kustomize-check, kustomize-listing, secrets-placement,
                      # release-secrets, db-url-check (widened), oidc-check,
                      # grafana-oidc-check, open-webui-oidc-check, crd-check, tesla-forwarder-test
make dry-run DRYRUN_CONTEXT=<admin context>   # skips out loud without one; still run if one exists
```

Live, in order, each step a fact rather than a hope:

1. `kubectl -n databases get database open-webui,databaserole open-webui` → `Database` reaches
   `Phase: completed`; a `Database` stuck `Reconciling` past a minute is a real failure, not a race.
2. `kubectl -n open-webui get pod` → `Running`, and the logs show Alembic migrations completing
   against the non-superuser role (§5.1).
3. `kubectl -n certificates get certificate titan-wildcard -o jsonpath=...` and
   `kubectl -n open-webui get secret titan-tls` → the reflected Secret exists; if it does not, the
   allow-list edit (§8.3) is half done.
4. `curl -sI https://open-webui.titan.arrieta.eu` → 200 or a redirect to the login, not a Traefik 404.
5. Sign in with an `authentik Admins` member → open-webui `admin`. **Record the `redirect_uri` on the
   wire** and narrow the blueprint (§7.2).
6. Sign in with a non-admin authentik user → `user`, not `pending`, not 403.
7. Add the llama.cpp connection in the admin UI, chat once, then `kubectl -n open-webui delete pod`
   and confirm: the session survives, the stored OAuth token still decrypts (no `InvalidToken` in
   the new pod's log), and the chat is still there. Step 7 is the acceptance test for §6 and for D2
   together, and it is the one step casa would currently fail.
