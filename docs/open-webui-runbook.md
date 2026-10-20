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
kubectl -n open-webui get secret titan-tls          # Reflector's job, not yours
curl -sI https://open-webui.titan.arrieta.eu       # 200, not a TLS error
```

Then the four things only a human can check: admin login lands, a non-admin login lands, a
non-member is refused, and `kubectl -n open-webui delete pod` leaves the session and the stored
OAuth token intact — that last one is the proof §2 is real rather than theoretical.

## 7. Not proven / not done

- `uploads/` is unbacked (§1). No plan yet; the PV's `Retain` is a deletion mitigation, not a backup.
- The non-superuser `DatabaseRole` is an argument from absence (chroma, not pgvector). It is proven
  only by a successful migration run on the live cluster. If a migration ever needs elevation, the
  pod fails at Alembic and the fix is a deliberate `superuser: true` with its own note — not a
  silent widening.
- Inference is not wired: no llama.cpp endpoint is configured. It is reachable from the LAN; that has
  not been proven from inside a pod, so nobody should promise it works until something answers.
- The `local-path-retain` PVC has never been restored on this cluster.
