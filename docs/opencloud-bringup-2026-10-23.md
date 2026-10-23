# OpenCloud bring-up on titan — 2026-10-23

OpenCloud replaced the oCIS instance that had been running on k8s-casa. It is live at
`files.titan.arrieta.eu`, namespace `files`, one container (`apply/50-apps/opencloud/opencloud.yaml`)
with S3/MinIO as primary storage. This file records what was actually observed working, what had to be
fixed to get there, and what is still unproven.

Read this before trusting any claim in `docs/opencloud-admin.md` or `docs/opencloud-minio.md` about
what has been tested — those describe mechanisms; this records outcomes.

## What is proven, with the evidence

| claim | evidence |
|---|---|
| web login through authentik + Google | session established, files listed |
| an upload really reaches MinIO | object present in bucket `opencloud-blobs` after a web upload |
| **Android login** | `opencloud-eu/android` v1.2.5 logged in and synced; authentik shows 0 `Flow non applicable` and one successful `/source/oauth/callback/google/` in the window |
| **desktop client login** | operator tested 2026-10-23 — works |
| webfinger `client_id` handoff | the desktop client found the OIDC issuer and client without being configured with either — the whole reason the port was worth doing |
| the OIDC application rejects unregistered redirect URIs | tested, not assumed |
| **administrator role granted** | operator reached the admin section of the web UI after `OC_ADMIN_USER_ID` landed (`docs/opencloud-admin.md`) |
| **Collabora editing works** | operator edited a spreadsheet end to end, 2026-10-23 |
| basic auth works with an app token | `GET /graph/v1.0/me` returned 200 with username + app token; the token was revoked afterwards |

## What had to be fixed

Three failures shipped with the port. Each is in git; none is a live hand-edit.

| symptom | real cause | fix |
|---|---|---|
| CSP not applied; the web UI blocked its own frame | the CSP ConfigMap was mounted one directory above the path `PROXY_CSP_CONFIG_FILE_LOCATION` names | mount at the exact file path |
| identity store half-populated, LDAP errors for accounts that exist | IDM's only bootstrap guard is `os.Stat` on the boltdb, and the file is created before the LDIF import finishes | see `docs/opencloud-idm-bootstrap.md` — the hazard and the recovery |
| **mobile and desktop logins refused** after Google accepted the password, while web worked | clients send `prompt=login`, which re-enters the **source** flow; that flow ships `require_unauthenticated` and refuses an authenticated session | `authentication: none` on `default-source-authentication`, asserted from the blueprint — `docs/authentik-runbook.md` §12 |

The third is the expensive one and the log line that explains it contains no flow slug. If mobile login
breaks after an authentik upgrade, check that field before anything else.

## What is NOT proven

- **Nothing here is backed up.** Postgres has base backups and WAL archiving; the `opencloud-data` PVC
  does not, and this repo ships no generic PV backup at all. The file *contents* live in casa's MinIO and
  the *metadata tree and IDM boltdb* live on the PVC. A PVC loss means accounts, shares and the storage
  tree are gone even if the blobs survive. This is the largest open gap.
- **Restore has never been exercised.** No snapshot of the PVC or the bucket has been taken and put back.
- **Role mirroring is deliberately off.** `PROXY_ROLE_ASSIGNMENT_DRIVER` is `default`, so everyone gets
  the plain `user` role and admin comes from the single `OC_ADMIN_USER_ID`. The claim path works but
  assignments append and nothing removes them, so authentik can grant admin and cannot revoke it —
  `docs/opencloud-admin.md`.
- **Token expiry and re-auth have not been observed** on any client. Every login above was a fresh one.
- **Collabora under concurrent load**, and Collabora's behaviour when WOPI is slow, are untested.
- **Web app installation is not yet done.** Apps are files under
  `/var/lib/opencloud/web/assets/apps` on the PVC; nothing installs any yet. draw.io and Importer are
  scoped but unbuilt — Importer additionally needs a Uppy Companion service and its own OAuth credentials.

## Corrections to earlier notes

Two claims made during the port were wrong and are recorded here so nobody re-derives them:

- The Collabora readiness probe was said to log a failure every 20s while reporting success. **Not
  reproducible** — `/readyz` on 9205 shows no failures and the pod is Ready. Treat that claim as
  withdrawn.
- Role mirroring was said to need a scope the clients do not request and a config file for
  `role_mapping`. **Both false** — `groups` rides the `profile` scope that web, Android, desktop and iOS
  all already request, and the shipped default `RolesMap` covers the standard roles. See
  `docs/opencloud-admin.md`.
