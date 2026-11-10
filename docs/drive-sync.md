# Google Drive → OpenCloud import

`apply/50-apps/opencloud/drive-sync.yaml` runs `rclone copy` nightly from a Google Drive account
into `files.titan.arrieta.eu`. This file is the procedure for putting credentials into it, because
none of the three credentials can be produced from a git checkout.

**Read the header of that file before this one.** It records why the job is one-way, and the
one-way-ness is the safety property, not a limitation: `rclone copy` cannot delete at the
destination, and neither half of OpenCloud is backed up (spec 4 of
`docs/superpowers/specs/2026-10-22-titan-restic-pv-backups-design.md`), so a sync that could delete
would be a data-loss path with no net under it.

## Where the files land, and why not Personal

The import writes to a **project space** named `google-drive-archive`, not to the Personal space.

The reason is the desktop client. It mirrors Personal, so an import landing there pulls ~31 GB onto
every laptop that syncs it, and the only defence is the client's **Choose What to Sync** checkbox —
per device, and one accidental re-tick away from being undone. A space the client does not sync has
no such lever to get wrong.

**The space id is not the bare UUID, and guessing wastes an hour.** Measured against live OpenCloud
on 2026-11-10:

| Path tried under `/remote.php/dav/spaces/` | Result |
| --- | --- |
| `<uuid>` | `directory not found` |
| `google-drive-archive` (the slug) | `directory not found` |
| `<uuid>!<nodeId>` | `directory not found` |
| `<uuid>$<nodeId>` | **works** |
| the collection root, no id | `405 Method Not Allowed` on PROPFIND |

The working form is the one the web UI already shows you: open the space and read the **`fileId`
query parameter** of `/files/spaces/project/<slug>` — it is
`<spaceId>$<nodeId>!<nodeId>`, and you want the part before the `!`.

Verified end to end with the app token before committing: listed the space root, wrote a probe file,
read it back with mtime intact to sub-second precision, deleted it cleanly. The destination in the
CronJob is the space **root**, so OpenCloud's own `.space/` metadata directory sits alongside the
imported tree; `copy` walks the source only, so rclone never touches it.

## App tokens are already enabled — this was assumed otherwise once

Two settings gate app tokens, and **both are already on** in this deployment:

| Setting | State on titan |
| --- | --- |
| `PROXY_ENABLE_APP_AUTH` | **defaults to `true`** in 8.1.0 — `services/proxy/pkg/config/defaults/defaultconfig.go:116` |
| `auth-app` service | runs by default; the App Tokens page in the UI is the proof |

`apply/50-apps/opencloud/opencloud.yaml` names both explicitly anyway. Not because they are
missing — because the nightly import rests on them and an upstream default flip should fail in
review rather than at 04:00.

This was **verified live, not inferred**: an app-token WebDAV listing of the personal space against
`https://files.titan.arrieta.eu/remote.php/webdav/` succeeded with *neither* variable present in the
running environment. An earlier draft of this doc claimed app tokens were disabled until this PR
landed; that was wrong, and believing it would have wasted a merge cycle waiting for something that
was never blocked. Check the running system before treating a manifest as the truth.

`AUTH_APP_ENABLE_IMPERSONATION` stays unset; its own description says *"Do NOT use in productive
deployments"*.

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
*"only the UUID can be used"* as the WebDAV username. **On this deployment the login name works** —
`javier` authenticated over WebDAV and listed the personal space, so the UUID fallback was not
needed. Keep reading anyway, because it is the first thing to try if a future account 401s: the
UUID is shown on the **Preferences** page.

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
scope = drive.readonly
token = <output of `rclone config get gdrive.token`>
team_drive =

[titan]
type = webdav
url = https://files.titan.arrieta.eu/remote.php/dav/spaces/<spaceId>$<nodeId>/
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

## 6. It is enabled — how to tell a run actually worked

`spec.suspend` is `false`; the import runs nightly at 04:00 UTC. To run one on demand:

```
kubectl -n files create job drive-sync-once --from=cronjob/drive-sync
kubectl -n files logs -f job/drive-sync-once
```

**Do not judge a run by its tail.** `rclone copy` exits 0 having transferred nothing, and the log is
mostly INFO-level `Copied` lines, so a run that dropped files reads identically to one that did not.
The two checks that mean something:

```
kubectl -n files logs job/drive-sync-once | grep -c ERROR      # must be 0
kubectl -n files logs job/drive-sync-once | grep -E "ERROR|Duplicate" | head
```

`Failed to read metadata: object not found` at INFO level is noise — rclone probing the destination,
one line per file. `Duplicate object found in source - ignoring` at NOTICE level is **not** noise: it
means Drive held two different files at the same path and only one was written. See the manifest
header for the measured count and why there is no flag that fixes it.

A manual job is not owned by the CronJob, so it does not consume a history slot — and it is deleted
by hand when you are done with it, not by the TTL.

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

- **Both credential paths are verified.** An app-token WebDAV listing returned the personal space,
  and a `drive.readonly` refresh token listed Drive, both with a real rclone binary against the
  committed `rclone.conf`. What has *not* been done is running the actual `rclone copy` inside the
  cluster — see the `suspend` note in the manifest header.
- **No alerting covers this job.** titan runs no Prometheus; alert rules live in `../k8s-casa`
  alongside `titan-pv-backup-alerts.yaml`. Until a `kube_job_status_failed` and a staleness rule
  exist there, a sync that stops produces nothing at all. That is the same gap that let the restic
  lock failure (#240) run for 37h, and it should be closed before this is trusted.
- **Nothing imported here is backed up.** Safe only while Google Drive remains the source of truth.
  Deleting from Drive after a sync moves the only copy into an unbacked bucket.
- **The 5 Gi `opencloud-data` PVC holds the metadata tree**, not the bytes (those go to casa's
  `opencloud-blobs` bucket). Fine for tens of thousands of files; nobody has measured where it
  stops being fine.
