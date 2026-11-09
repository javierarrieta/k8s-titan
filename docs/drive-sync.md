# Google Drive → OpenCloud import

`apply/50-apps/opencloud/drive-sync.yaml` runs `rclone copy` nightly from a Google Drive account
into `files.titan.arrieta.eu`. This file is the procedure for putting credentials into it, because
none of the three credentials can be produced from a git checkout.

**Read the header of that file before this one.** It records why the job is one-way, and the
one-way-ness is the safety property, not a limitation: `rclone copy` cannot delete at the
destination, and neither half of OpenCloud is backed up (spec 4 of
`docs/superpowers/specs/2026-10-22-titan-restic-pv-backups-design.md`), so a sync that could delete
would be a data-loss path with no net under it.

## What has to be true first

Two switches in `apply/50-apps/opencloud/opencloud.yaml` gate app tokens, and both were off before
`drive-sync.yaml` landed:

| Setting | Why |
| --- | --- |
| `OC_ADD_RUN_SERVICES: collaboration,auth-app` | the token-minting service has to run |
| `PROXY_ENABLE_APP_AUTH: "true"` | the proxy has to accept the tokens it mints |

**Deploy those before minting an app token.** With app auth off the web UI still creates tokens,
still lists them, and WebDAV still answers `401` to every request made with one — which reads as a
corrupt token rather than as a disabled feature. `AUTH_APP_ENABLE_IMPERSONATION` stays unset; its
own description says *"Do NOT use in productive deployments"*.

## 1. Google OAuth client — the part that bites

Create a Google Cloud project → OAuth consent screen → **External**, and set publishing status to
**In production**. Then *APIs & Services → Credentials → Create credentials → OAuth client ID →
Desktop app*.

**Do not leave it in `Testing`.** Google's documented rule is that an External app in `Testing`
gets *"a refresh token expiring in 7 days"*. For a laptop one-off that is an annoyance. For a
nightly CronJob it means the import silently dies on day eight. You will find the top-ranked forum
answers telling personal users to stay in Testing and add themselves as a test user — that advice is
correct for a one-off and wrong here.

In production + unverified is fine for a single personal user: you get a scary consent screen once,
and a refresh token that lives until you revoke it.

Also: do not use rclone's built-in shared `client_id`. rclone's own docs say it is being retired
during 2026, and it is a pooled quota — a large first run through it degrades to kilobytes per
second because you are sharing a global per-minute limit with every rclone user.

## 2. Mint the Google refresh token

On any machine with a browser (rclone is not installed in these workspaces):

```
rclone config create gdrive drive
```

Paste the client id and secret, choose scope `drive`, and complete the browser flow. Then read the
resulting token line back out — this is the value that goes into the Secret:

```
rclone config get gdrive.token
```

## 3. Mint the OpenCloud app token

Log in at `files.titan.arrieta.eu` → account menu → **Manage account → App Tokens → New**, choose an
expiry, and copy it immediately; it is shown once.

**The WebDAV username is the trap.** This deployment autoprovisions accounts from authentik
(`PROXY_AUTOPROVISION_ACCOUNTS=true`), and OpenCloud's own docs warn that under autoprovisioning
*"only the UUID can be used"* as the WebDAV username. Your login name may also work — try it, and if
WebDAV keeps answering 401 use the UUID shown on the **Preferences** page instead.

Obscure the token for the config file — rclone never stores a plaintext password:

```
rclone obscure '<app-token>'
```

## 4. Assemble the config

```ini
[gdrive]
type = drive
client_id = <from step 1>
client_secret = <from step 1>
scope = drive
token = <output of `rclone config get gdrive.token`>
team_drive =

[titan]
type = webdav
url = https://files.titan.arrieta.eu/remote.php/webdav/
vendor = infinitescale
user = <username, or the UUID from step 3>
pass = <output of `rclone obscure`>
owncloud_exclude_shares = true
```

`vendor = infinitescale`, **not** `opencloud`. OpenCloud's upstream migration guide writes
`vendor = opencloud`, but rclone has no such vendor — `backend/webdav/webdav.go` logs
`Unknown vendor` and falls back to generic WebDAV, which silently drops mtime preservation, SHA1
verification and tus chunked uploads. `infinitescale` is the correct quirk set because OpenCloud is
a fork of Infinite Scale.

Sanity-check it locally before encrypting anything:

```
rclone lsf gdrive: --max-depth 1
rclone lsf titan: --max-depth 1
```

Both must list. If `titan:` 401s, the app token is wrong, expired, or app auth is not deployed —
do not proceed until it lists.

## 5. Encrypt it into the tree

The Secret already exists holding a placeholder. Replace that one key without ever printing the
secret:

```
python3 -c 'import json,sys; print(json.dumps(open("rclone.conf").read()), end="")' \
  | sops set apply/10-secrets/drive-sync-secrets.yaml '["stringData"]["rclone.conf"]' --value-stdin
```

Note the argument order — file before index. `--value-file` errors with `Invalid set index format`
in sops 3.13.3, which is why this is `--value-stdin` with a JSON-encoded string.

If you re-encrypt the whole file instead of using `set`, **never** `sops --encrypt <tmp> > apply/10-secrets/<file>`:
sops matches creation rules against the *input* path, so it dies with `no matching creation rules
found` *after* the redirect has already truncated the destination to zero bytes. Encrypt to a temp
file, confirm it is non-empty, then move it into place.

## 6. Turn it on

Flip `spec.suspend: false` in `apply/50-apps/opencloud/drive-sync.yaml`, commit, let Flux sync.
Then run it once by hand rather than waiting for 04:00 — a suspended CronJob still allows a manual
job:

```
kubectl -n files create job drive-sync-once --from=cronjob/drive-sync
kubectl -n files logs -f job/drive-sync-once
```

The preflight in the job names the failing side explicitly, so `Google Drive rejected the token` and
`OpenCloud WebDAV rejected the app token` are different diagnoses and neither is a guess.

## Rotation and expiry

- **App token** — pick a long expiry when you mint it. Nothing in this tree can tell you it is about
  to lapse; the first sign is the job failing. Put it in whatever you use for recurring tasks.
- **Google refresh token** — lives until revoked, provided step 1 was done properly. If the job
  starts failing with an auth error after working, suspect the consent was revoked or the client was
  moved back to Testing.
- **Deleting a token** — Settings → App Tokens → delete. The job fails immediately, which is the
  confirmation.

## What is not proven

Nothing in this file has been executed end to end. Specifically:

- **The app-token path is unverified on this deployment.** `PROXY_ENABLE_APP_AUTH` and `auth-app`
  were added in the same commit as this doc; nobody has watched a WebDAV request succeed with an app
  token yet.
- **Whether the login name or the UUID is the WebDAV username here is unknown.** Step 3 gives the
  decision rule rather than the answer.
- **No alerting covers this job.** titan runs no Prometheus; alert rules live in `../k8s-casa`
  alongside `titan-pv-backup-alerts.yaml`. Until a `kube_job_status_failed` and a staleness rule
  exist there, a sync that stops produces nothing at all. That is the same gap that let the restic
  lock failure (#240) run for 37h, and it should be closed before this is trusted.
- **Nothing imported here is backed up.** Safe only while Google Drive remains the source of truth.
  Deleting from Drive after a sync moves the only copy into an unbacked bucket.
- **The 5 Gi `opencloud-data` PVC holds the metadata tree**, not the bytes (those go to casa's
  `opencloud-blobs` bucket). Fine for tens of thousands of files; nobody has measured where it
  stops being fine.
