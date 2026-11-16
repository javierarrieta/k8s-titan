# Vikunja on titan — design

Vikunja (task manager) at `tasks.titan.arrieta.eu`, Postgres in the shared CNPG cluster, sign-in
through authentik, outbound mail through the existing `mail.techdelivery.es` relay. Written
2026-11-16.

Everything asserted below as *measured* was measured in this session against either the upstream
source at 2.8.0, the live cluster through the read-only `k8s-reader` identity, or a file in one of
the sibling repos. Assertions that were **not** measured are collected in §9 rather than written as
though they were.

## 1. What it is, and why it is a new namespace

One container. The official image is `FROM scratch`, runs as uid 1000, listens on `:3456`
(`service.interface` default), and serves the API and the built frontend from the same process —
there is no sidecar and no separate web tier. Attachments and avatars go to `/app/vikunja/files`.
Redis is optional and off by default (`redis.enabled: false`, `keyvalue.type: memory`), so unlike
Sure this app buys no second datastore.

It owns a database, so it fails the §3.1 admission test of
`2026-10-19-titan-app-scale-out-design.md` on the hard list and gets namespace `vikunja`. It does
**not** get a stage: two hand-written manifests, no bulk authored here, so it stays in the shared
`apps` unit under the cost that unit's own header records — a malformed field here freezes coder's
and authentik's *updates*, not coder.

## 2. Decisions

| # | decision | why |
|---|---|---|
| D1 | own namespace `vikunja`, shared `apps` stage | Own database fails §3.1's hard list; §3.2 keeps it in `apps`. Same call mealie and Sure made on the same shape. |
| D2 | Postgres in the shared CNPG cluster | sqlite would live on the PVC and the PVC is a different backup path with no consistency point between them (§4). `Database`/`DatabaseRole` in `databases`, named `vikunja` — no hyphen, so none of open-webui's quoted-identifier translation to get wrong. `login: true`, not superuser: migrations are ordinary DDL in its own schema. |
| D3 | hand-written Deployment, not the official Helm chart | Vikunja is one container, so a chart buys little, and `go-vikunja/helm-chart` (bjw-s common library, created 2025-05) buries ~20 env vars under `workload.main.podSpec…`. Several of those vars fail silently (§2 D6, D8, D12), and this tree's convention is a comment next to each one. `secret-refs` walks built Deployments, so a typo'd Secret name fails offline. Cost accepted: a malformed field freezes coder's and authentik's updates. |
| D4 | image pinned `docker.io/vikunja/vikunja:2.8.0` | Fleet rule, never `:latest`. 2.8.0 is current. Chose over 2.7.x because the `groups` claim for team sync and the `tk_`-token CalDAV auth both landed before it. Images are cosign-signed since 2.7.1; verification is out of scope here. |
| D5 | authentik OIDC via a blueprint **Secret**, mounted by the HelmRelease | authentik ships no CRDs, so a blueprint is the only declarative path. Secret not ConfigMap because it carries the client secret. It must be added to `blueprints.secrets` **and** to the worker's reloader annotation — a mounted-but-unreloaded blueprint lands up to an hour late and reads as "my change did nothing" (`blueprint-mount-check`, #192's finding). |
| D6 | **no `email_verified` opt-out** | This is the deliberate difference from coder (`CODER_OIDC_IGNORE_EMAIL_VERIFIED`) and Mealie (`OIDC_REQUIRES_EMAIL_VERIFICATION=false`), and it will be misread as an omission unless it is written down. Read at 2.8.0, `pkg/modules/auth/openid/openid.go`: identity is `issuer + sub` (`getOrCreateUser` looks the user up by those two and nothing else), and `email_verified` is consulted **only** inside `fallbackSearchUsers`, the deprecated `emailfallback` local-account-linking path that `auth.local.enabled: false` makes unreachable. The `email` claim *is* required — `mergeClaims` returns `ErrNoOpenIDEmailProvided` when it is empty and userinfo cannot supply it — and authentik's managed email mapping always emits it (with `email_verified: false`, which Vikunja then ignores). So there is nothing to opt out of. |
| D7 | `VIKUNJA_AUTH_LOCAL_ENABLED=false`, `VIKUNJA_SERVICE_ENABLEREGISTRATION=false` | One door, and it is authentik's. Same reasoning as mealie's `ALLOW_PASSWORD_LOGIN=false` and open-webui's `ENABLE_LOGIN_FORM=false`: a local password form beside SSO is a second, unbacked door. Consequence recorded in §9: these users have no password, which changes how CalDAV authenticates. |
| D8 | `VIKUNJA_SERVICE_SECRET` from a Secret, mandatory | `generateServiceSecretIfEmpty()` in `pkg/config/config.go` mints a random secret when none is configured, and the documented effect is that **every already-issued token is invalid after a restart**. With `strategy: Recreate` — forced by the RWO PVC — that is every deploy logging every session out. `service.JWTSecret` is the deprecated alias; use `service.secret`. |
| D9 | `VIKUNJA_SERVICE_IPEXTRACTIONMETHOD=xff`, `VIKUNJA_SERVICE_TRUSTEDPROXIES=10.62.0.0/16` | Default is `direct`, which reads the TCP peer: behind Traefik every log line and every entry in a user's session list says the Traefik pod address instead of the client. `10.62.0.0/16` is the measured pod CIDR (Traefik pod `10.62.0.219`, mealie pods in the same range, read live 2026-11-16). Honest limit, stated because upstream states it: trusting the pod CIDR means any pod in the cluster can forge `X-Forwarded-For`. That is acceptable *today* only because `ratelimit.enabled` (default false) and `audit.enabled` (default false) are both off, so the sole consumer of client address is attribution. If either is ever switched on, this line stops being cosmetic and the forgeability becomes the finding. |
| D10 | `VIKUNJA_DATABASE_MAXOPENCONNECTIONS=10`, `VIKUNJA_DATABASE_MAXIDLECONNECTIONS=2` | Defaults are 100 open / 50 idle — from one app, into a single-instance Postgres that authentik, coder, open-webui, Sure, Mealie and Portfolio Prism all share. The two knobs do different jobs and both are being moved. **Idle** is the steady-state one: those are backends held open while nothing is using them, and 50 of them for a two-person task manager is pure parked cost. **Open** does nothing in normal operation — the pool never grows to the ceiling unless something is slow — so its only real function is bounding the stall case, where a Postgres hiccup makes every in-flight request keep its backend until they would stop at the ceiling. 10 is that bound. Not lower: an exhausted pool makes requests **block** rather than error, so one slow query (a large task list, a CalDAV `report`) would queue everything behind it and read as a hang with nothing in the log — the healthy-and-broken-look-identical class this repo keeps tripping over. `maxconnectionlifetime` stays at its 30-minute default, so connections recycle without help. The cluster's own `max_connections` is **unknown from here** (§9), so this bounds our footprint rather than computing headroom. |
| D11 | `VIKUNJA_DATABASE_SSLMODE` left at its default `disable` | Matches mealie, open-webui and Sure on the same `postgres-rw.databases.svc` path; the connection never leaves the node. Not a regression to "fix". |
| D12 | mailer **on**, relaying through `mail.techdelivery.es:465` | Operator decision, taken with the trade-off in §6 written down. `VIKUNJA_MAILER_FROMEMAIL` must equal the mailbox address because the relay runs `SPOOF_PROTECTION=1`. |
| D13 | `VIKUNJA_SERVICE_TIMEZONE=GMT` | Operator decision 2026-11-16. **This is already the default** (`ServiceTimeZone.setDefault("GMT")`), so the line is a pin that documents intent and survives a future default change; it moves no behaviour by itself. Whether the `09:00` overdue digest uses this or each user's own timezone is unverified (§9). |
| D14 | probes on `/health` | `pkg/routes/routes.go:252` registers `GET /health` and it is public unless `health.username`/`health.password` are set, which they are not. Budgeted as a `startupProbe` because migrations run against Postgres at boot and are unbounded on a slow node. |
| D15 | `runAsUser: 1000`, `runAsGroup: 1000`, `fsGroup: 1000` | The image's own user is uid 1000 (upstream: "runs as user 1000 and no group", gid 0). Running the group as 1000 rather than 0 is a deliberate narrowing; `fsGroup` is what makes the mounted PVC writable by it, and grafana and mealie are the live proof that fsGroup is honoured against `local-path-retain` on this cluster. First boot is the proof for uid 1000 specifically (§9). |
| D16 | `strategy: Recreate` | RWO PVC: a RollingUpdate schedules pod 2 while pod 1 still holds the volume and it sits Pending on a volume conflict forever. |
| D17 | PVC 5Gi `local-path-retain`, opted in to restic with `backup.titan.arrieta.eu/class: daily` | Attachments and avatars are user-created and exist nowhere else, so unlike the Grafana volumes there is a real loss here. `local-path-retain` is a deletion mitigation, not a backup. What a restore actually returns is §4. **The annotation is one line and the wiring is four coordinated edits**: a discovery CronJob in `apply/70-backup/runner.yaml`, the runner and job RBAC in `apply/70-backup/rbac.yaml`, and **both** mirror keys — `reflection-allowed-namespaces` and `reflection-auto-namespaces` — on **two** objects, the `apply/70-backup/preflight.yaml` ConfigMap and the sops-encrypted `apply/10-secrets/backup-minio-secrets.yaml`. `make backup-coverage` is what proves the annotation, the runners, the mirrors and the RBAC agree, and it was red for exactly this reason when the annotation landed ahead of the wiring. |
| D18 | CalDAV left at its default (enabled) | `service.enablecaldav` defaults true. With D7 there is no password to use, but since 2026-03-30 CalDAV also accepts `tk_` API tokens carrying the `caldav` permission, which is the path these users have. Untested (§9). |
| D19 | `VIKUNJA_SENTRY_ENABLED=false`, explicit | Already the default. The Sentry DSN is compiled into the binary, so this is a pin against a future default flip, not a fix for anything. |
| D20 | no team sync — `scope: openid profile email`, no `groups` | Team sync from the `groups` claim exists from 2.8.0 but every group name becomes a team, and nothing here needs Vikunja teams to mirror authentik groups. YAGNI. Recorded so that adding `groups` to that scope is understood as a behaviour change rather than a scope tidy-up: it switches the sync on. |
| D21 | a new gate, `make vikunja-check` | §7. |
| D22 | the Ingress is pinned to `websecure` (`traefik.ingress.kubernetes.io/router.entrypoints: websecure`) | This Traefik runs no HTTP->HTTPS redirect (`apply/20-infra/traefik/traefik.yaml:250`), so an Ingress that pins nothing gets a router on `:80` as well and `http://tasks.titan.arrieta.eu/` serves the app in cleartext. D7 leaves these users with no password, so the credential on this host is the long-lived `tk_` API token D18's CalDAV path carries over HTTP Basic — a long-lived bearer credential must not be offerable on `:80`. Same call `llm` and `investing-agent` made on the same shape, for the same reason. Enforced rather than commented: `PIN_REQUIRED` in `tools/ingress-auth-check.py` fails when the annotation is missing. Honest limit, the one `apply/50-apps/llm/llm.yaml` states first: pinning makes an `http://` request *unserved* (404), not safe — a client configured with `http://` has already put the token on the wire before anything can judge it. |

## 3. Files

New:

- `apply/50-apps/vikunja/vikunja-db.yaml` — CNPG `Database` + `DatabaseRole` in namespace `databases`.
- `apply/50-apps/vikunja/vikunja.yaml` — PVC + Deployment + Service + Ingress in namespace `vikunja`.
- `authentik/blueprints-vikunja.yaml` — template with `${VIKUNJA_OIDC_CLIENT_ID}` / `${VIKUNJA_OIDC_CLIENT_SECRET}`.
- `scripts/setup-vikunja-secrets.sh` — renders the blueprint and writes the three sops Secrets (`scripts/setup-mealie-secrets.sh` is the template).
- `apply/10-secrets/vikunja-secrets.yaml` — six keys, each named exactly as Vikunja reads it, so the Deployment uses plain `envFrom` with no aliasing: `VIKUNJA_SERVICE_SECRET`, `VIKUNJA_DATABASE_PASSWORD`, `VIKUNJA_AUTH_OPENID_PROVIDERS_AUTHENTIK_CLIENTID`, `…_CLIENTSECRET`, `VIKUNJA_MAILER_USERNAME`, `VIKUNJA_MAILER_PASSWORD`. `stringData`, never `data:` — `secrets-placement` rejects `data:` in that directory because a sops ciphertext is not base64.
- `apply/10-secrets/vikunja-db-credentials.yaml` — the CNPG `passwordSecret` (`password`, plus `username`), in `databases`.
- `apply/10-secrets/authentik-vikunja-blueprint.yaml` — the rendered blueprint.
- `tools/vikunja-check.py`.

Edited:

- `apply/50-apps/kustomization.yaml` — list both manifests, DB first (intent, not mechanism).
- `apply/00-bootstrap/namespaces.yaml` — `vikunja`.
- `apply/50-apps/auth/authentik.yaml` — `blueprints.secrets` list **and** the worker reloader annotation.
- `apply/20-infra/reloader/reloader.yaml` — `vikunja` joins `namespaces`. Without this the Deployment's `reloader.stakater.com/auto` annotation is inert and a rotated secret sits unread in a running pod; promtail's entry in that list is the recorded precedent for how expensive that reads.
- `apply/40-certificates/titan-wildcard.yaml` — `vikunja` in **both** `reflection-allowed-namespaces` and `reflection-auto-namespaces`. Editing one and not the other leaves the Certificate Ready and the Secret absent.
- `AGENTS.md` — the prose copy of that allow-list. `tls-reflection-check` fails when the file's copy drifts from the annotation it quotes.
- `tools/ingress-auth-check.py` — `("vikunja","vikunja")` in `NOT_PROXY_GATED` with the citation.
- `Makefile` — the `vikunja-check` target, in `check` (it reads sops) and not in `check-ci`.
- `apply/70-backup/runner.yaml`, `apply/70-backup/rbac.yaml`, `apply/70-backup/preflight.yaml` and
  `apply/10-secrets/backup-minio-secrets.yaml` — the restic wiring D17's annotation depends on. Four
  files, four edits, one gate: see D17 and `make backup-coverage`.

## 4. What is in Postgres, what is on the PVC, and what a restore returns

Postgres (`vikunja`, in the cluster that ships base backups and WAL to S3) holds users and their
OIDC identities (`issuer` + `subject`), projects, tasks, checklists, labels, comments, shares,
webhooks and the attachment **rows**. The PVC holds the attachment **bytes** and avatars, under
`/app/vikunja/files`.

Both halves are backed up, which is more than mealie's split gives you. What is *not* true is that
they are consistent with each other: the CNPG base backup and the restic snapshot are two
independent schedules with no shared point in time, so a restore can return an attachment row whose
bytes are not in the snapshot, or bytes no row names. That is a degraded restore, not a corrupt
database, and it is stated here rather than discovered during an incident.

## 5. The OIDC contract

- Application and provider slug `vikunja`, `issuer_mode: per_provider`, so the issuer — and therefore `VIKUNJA_AUTH_OPENID_PROVIDERS_AUTHENTIK_AUTHURL` — is `https://auth.titan.arrieta.eu/application/o/vikunja/`.
- Confidential client, Authorization Code, `redirect_uris` = `https://tasks.titan.arrieta.eu/auth/openid/authentik` with `matching_mode: strict`. The path is `/auth/openid/<provider-id>`, where the provider id is the YAML key `authentik`; it is uppercased to `AUTHENTIK` only in the env var name, because `setConfigFromEnv` lowercases every segment it splits on `_`. So `VIKUNJA_AUTH_OPENID_PROVIDERS_AUTHENTIK_CLIENTID` and that URI are one fact kept in two files, which is what `vikunja-check` compares. A provider key containing an underscore would not survive that split at all; `authentik` does. That the path is `/auth/openid/…` at all is asserted here and never measured (§9).
- Property mappings `openid`, `email`, `profile`. `profile` is what carries `preferred_username`; without it Vikunja falls back to `nickname` and then to a generated pet-name, so a login that "works" produces a user with a nonsense username and no error anywhere.
- RP-Initiated Logout: `…_AUTHENTIK_LOGOUTURL` = `…/o/vikunja/end-session/`, so logging out of Vikunja does not leave the authentik session standing.
- The Application carries a `policy_engine_mode: any` binding to `titan-family`, the same gate mechanism mealie and Portfolio Prism use — mechanism, not set: mealie binds `titan-family` **and** `titan-mealie-admins`, this binds `titan-family` alone. A binding naming a group that does not exist **denies**.
- No `groups` scope (D20).

## 6. Outbound mail

`mail.techdelivery.es` is a docker-mailserver on the VPS that is being drained. It is the MX for
`arrieta.eu`, `arrieta.es`, `arrieta.nom.es`, `collegia.es`, `iurbana.org` and `techdelivery.es`,
and `k8s-techdelivery/apply/50-apps/apps/mailserver-runbook.md` records DKIM signing proven
end-to-end on 2026-10-01 for all six with selector `mail` — proven by delivering a message to
Gmail and reading `Authentication-Results`, not by configdump, because "a key that fails to load
produces no header and no obvious error".

Settings and why each is what it is:

| key | value | why |
|---|---|---|
| `MAILER_HOST` | `mail.techdelivery.es` | The submission host. `smtp.techdelivery.es` is the same box and is what the HELO announces; the runbook's own 465 test submitted to this name. |
| `MAILER_PORT` | `465`, `MAILER_FORCESSL=true` | Implicit TLS. 465 is the port with a recorded end-to-end authenticated submission; 587/STARTTLS is also live and probed by gatus, but `forcessl` is the mode that refuses a downgrade rather than falling back to plaintext. |
| `MAILER_AUTHTYPE` | default `plain` | Safe under implicit TLS; dovecot offers PLAIN on submission. |
| `MAILER_FROMEMAIL` | `tasks@techdelivery.es` | **Must equal the mailbox.** The box runs `SPOOF_PROTECTION=1`, which restricts an authenticated user to its own address and aliases; a From that does not match is refused at `MAIL FROM`. `techdelivery.es` is also the one domain of the six where DMARC passes on SPF *as well as* DKIM, because SRS rewrites the envelope to that domain — so this address is the strongest of the six, not an arbitrary pick. |
| `MAILER_ENABLED` | `true` | Reminders are already on behind it (`service.enableemailreminders`, `defaultsettings.overdue_tasks_reminders_enabled`, both default true), so the mailer is the only switch. |

Two things to know before the first deploy, both from the box's own ConfigMap:

- **`ENABLE_FAIL2BAN=1`.** A wrong password from titan gets titan's address banned on a box titan
  does not own, and the symptom is "mail stopped working", not "auth failed". Test credentials
  once, deliberately, and do not retry in a loop.
- **The dependency is on a box being decommissioned.** That is the cost of this choice and it was
  taken with eyes open: the alternative was shipping without mail and wiring it when the mailserver
  moves to titan. When that move happens this change is a host name — and the runbook's own
  migration notes say the move needs `25 465 587 993 995` opened on titan and a PTR that matches the
  HELO, neither of which is done yet.

The mailbox itself lives in the config PVC, not in git — same class as the three follow-ups the
mailserver runbook already tracks as "cannot be expressed in Git". It is created out of band and
its credential is then rendered into `vikunja-secrets`.

## 7. The gate

`tools/vikunja-check.py`, in `check` (it reads sops-encrypted values) and not in `check-ci`. It
fails when:

1. the blueprint template, the rendered blueprint Secret, and the Deployment disagree on client id,
   issuer, or the redirect URI derived from `PUBLICURL` and the provider key;
2. the rendered blueprint is absent from `blueprints.secrets` or from the worker reloader
   annotation — the case `blueprint-mount-check` covers generically and `oidc-check` covers for
   coder and open-webui only;
3. the host in `VIKUNJA_SERVICE_PUBLICURL` is not the host on the Ingress. `PUBLICURL` is what
   Vikunja builds its own redirect URI from, so a mismatch is an authentik-side error with a
   Vikunja-side cause;
4. `vikunja-db-credentials` and `vikunja-secrets` carry different passwords. **No existing gate
   sees this**: `db-url-check` is reference-driven on `DATABASE_URL` / `*PG_CONNECTION_URL` and
   Vikunja takes split `VIKUNJA_DATABASE_*` keys, so the generic gate reports zero references and
   passes vacuously on this app. Same gap `sure-check` was written for from the other direction.
5. `VIKUNJA_MAILER_FROMEMAIL` is not the mailbox in `VIKUNJA_MAILER_USERNAME` — a mismatch is a
   refusal at `MAIL FROM` that the pod reports as healthy, and `SPOOF_PROTECTION` makes it
   structural rather than cosmetic.

Its honest limits are the fleet's: it proves names and agreement across files, never that authentik
applied the blueprint, that the relay accepted the credentials, or that a message was delivered.

## 8. Post-merge, in order

1. Create the mailbox on the mailserver (out of band, config PVC) and confirm it can submit —
   **one** authenticated test, because of fail2ban.
2. `scripts/setup-vikunja-secrets.sh` → the three sops Secrets.
3. Apply. The `Database`/`DatabaseRole` must reach `applied: true` before the app is useful; read
   `status.applied`, not `status.message` (AGENTS.md: the message is history, not state).
4. Confirm `titan-tls` actually landed in `vikunja`. `tls-reflection-check` proves the namespace is
   *allowed* the Secret, never that the mirror arrived.
5. Force the blueprint: `ak apply_blueprint`, rather than waiting on the hourly discovery pass
   (`docs/authentik-runbook.md` §5).
6. First login through authentik. Check the resulting username is a real one and not a pet-name
   (§5).
7. Send a test message. Vikunja ships a CLI mail test; confirm the command exists in 2.8.0 before
   promising it, then verify by reading the relay's log or the recipient's `Authentication-Results`
   — the runbook's lesson is that config-side evidence proves nothing about signing.
8. `make check`.

## 9. Not proven

Written down because every one of these would otherwise be discovered during an incident.

1. **The mailbox exists and authenticates.** Supplied as a credential file; never exercised.
   Compounded by fail2ban (§6).
2. **titan can reach `mail.techdelivery.es:465`.** Not testable from this workspace — this dev box
   is not titan. Probe from titan itself.
3. **`preferred_username` is actually in the token.** If it is not, logins succeed with generated
   pet-name usernames and nothing errors.
4. **Whether the `09:00` overdue digest uses `service.timezone` or each user's own timezone.**
   `defaultsettings.timezone` is a separate key and per-user timezone also governs due-date
   display. D13 is a pin, not a claim about digest timing.
5. **The Postgres `max_connections` ceiling.** `k8s-reader` cannot `pods/exec` in `databases`
   (measured Forbidden 2026-11-16), and `spec.postgresql.parameters` sets no `max_connections`, so
   it is whatever CNPG defaults to. D10 bounds our own footprint; it does not know the ceiling. Nor
   was Vikunja's per-request connection hold time measured — D10 is reasoned from the `config.go`
   defaults and how Go's `database/sql` pool behaves, not observed.
6. **uid/gid 1000 with `fsGroup` against `local-path-retain`.** Proven for grafana (fsGroup) and
   mealie (uid 911), not for this combination. First boot is the proof.
7. **A restore of this PVC.** Only `mealie/mealie-data` has ever been restored and verified
   (`pv-restore-drill.md`). A Vikunja restore needs the same elevated privileges that drill
   documented — `CHOWN` and `FOWNER`, which the nightly jobs' `drop ALL` + `DAC_OVERRIDE` do not
   have — and the same leading-slash path quirk.
8. **That the blueprint applied.** Mounting is not applying; §8 step 5 is the deterministic path and
   `blueprint-mount-check` proves only the wiring.
9. **CalDAV with a `tk_` token for an OIDC-only user.** Upstream documents the token path; it is
   untested here, and the older "account is not local" failure is a known shape for exactly this
   configuration. D22 narrows it further: the host answers on `websecure` only, so whether a real
   CalDAV client configured against a `websecure`-only host behaves as expected with a `tk_` token
   is part of what this item has not measured.
10. **Mobile-app OIDC.** Upstream documents webview cookie quirks and a "State does not match"
    failure class for OIDC in the mobile clients. Out of scope, recorded so it is not mistaken for
    a titan bug.
11. **The redirect URI path itself.** §5 states `/auth/openid/<provider-id>` flatly and
    `vikunja-check` compares two constants rather than computing that concatenation, so nothing has
    ever proven what Vikunja actually sends. The gate proves the two files agree with each other,
    which is not the same claim. What makes this a footnote rather than a blocker is that a wrong
    path fails **loudly** — authentik refuses an unregistered `redirect_uri` at the first real login
    — not silently.
12. **The backup chain, end to end.** No restic backup of `vikunja-data` has ever run, the `vikunja`
    discovery CronJob has never fired, and the MinIO credential mirrored into `vikunja` has never
    been used. That is a whole dependency chain added late — Reflector mirror → ServiceAccount/Role
    → CronJob → restic → casa's MinIO — and nothing has exercised any link of it. `make
    backup-coverage` proves the tree agrees; it cannot prove a Job would run. Item 7 is the restore
    side of the same unproven path.
