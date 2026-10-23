# The MinIO credential for OpenCloud's blob store

Prerequisite for the OpenCloud deployment. OpenCloud's `decomposeds3` storage driver keeps
file bytes in an S3 bucket on Casa's MinIO and only the metadata tree on titan's PVC — the
same split `apply/50-apps/ocis/ocis.yaml` documents for oCIS, and for the same reason: titan
has no room for the data.

**Status: the policy is proven against the live bucket; the driver has not run yet.** Every action
below was exercised with the real key against `opencloud-blobs` on 2026-10-22, and the denials are
the half that usually gets left too wide:

| probe | result |
|---|---|
| `ListBucket opencloud-blobs` | allowed |
| `PutObject` / `GetObject` / `DeleteObject` | allowed |
| `CreateMultipartUpload` + `UploadPart` + `ListParts` + `AbortMultipartUpload` | allowed |
| `ListBucket ocis-blobs` | **AccessDenied** — as intended |
| `GetObject ocis-blobs` | **AccessDenied** — as intended |
| `CreateBucket` | **AccessDenied** — as intended |
| `GetBucketLocation` | **AccessDenied** — as intended, see the region note |
| `ListMultipartUploads` | **AccessDenied** — a judgement call, see the last section |

What is still unproven is that the driver needs nothing else. A missing action would surface as
`AccessDenied` on upload from storage-users, not as a login failure.

## What the key actually needs

The only S3 client in this configuration is the blobstore, at
`vendor/github.com/opencloud-eu/reva/v2/pkg/storage/fs/decomposeds3/blobstore/blobstore.go`
in `opencloud-eu/opencloud`. Its entire call surface:

| call | line | IAM action |
|---|---|---|
| `PutObject` | `:87`, `:105` | `s3:PutObject` (+ multipart parts) |
| `GetObject` | `:122` | `s3:GetObject` |
| `RemoveObject` | `:141` | `s3:DeleteObject` |
| `ListObjects`, recursive | `:150` | `s3:ListBucket` |

`New()` (`:56-77`) builds a minio-go client with static credentials and an explicit region.
There is no `MakeBucket`, no `BucketExists`, no `CopyObject` and no bulk `DeleteObjects`. The
bucket must exist before the first start, and the key never needs bucket-write rights.

Policy: **`docs/opencloud-minio-policy.json`**. `s3:PutObject` covers
`CreateMultipartUpload` / `UploadPart` / `CompleteMultipartUpload` in AWS IAM semantics, which
MinIO honours; the two multipart actions are for aborting a half-finished upload, and
`PutObject` above 16 MiB does go multipart, so real uploads reach that path.

## Why the bucket cannot be shared with oCIS

`Path()` (`:170`) stores blobs at `<spaceID>/<pathified-blobID>` — root-level prefixes, no
common namespace. So the grant cannot be narrowed to a prefix, and `List()` walks the whole
bucket recursively. A shared `ocis-blobs` bucket would hand OpenCloud read access to every
oCIS blob and make the two products' maintenance commands interfere. Separate bucket,
separate key, so retiring oCIS later is one `mc admin user remove` rather than an audit.

## 1. Create the bucket

Needs admin; the key below never gets these rights.

```sh
mc mb local/opencloud-blobs
mc anonymous set none local/opencloud-blobs
```

Do **not** enable versioning. `RemoveObject` without a version ID writes a delete marker, so
every deleted file's bytes stay in the bucket forever. Combined with the orphaned-blob problem
(`opencloud-eu/opencloud` #2985 — blobs and user-index entries left behind when a space is
deleted and recreated, with no cleanup path) versioning would make you pay twice for garbage.

## 2. Issue the key

MinIO binds policies to **users**, not to service accounts — a service account inherits its
parent user's policy. If the service account already exists, find its parent first:

```sh
mc admin user svcacct info local <access-key>     # read the "Parent User" field
mc admin policy create local opencloud-blobs-rw docs/opencloud-minio-policy.json
mc admin policy attach local opencloud-blobs-rw --user <parent-user>
```

Attaching to the service account name does nothing, and silently. Older `mc` uses
`mc admin policy add` / `mc admin policy set`.

Then point the deployment at it:

| env var | value |
|---|---|
| `STORAGE_USERS_DECOMPOSEDS3_ENDPOINT` | `http://192.168.0.6:9000` |
| `STORAGE_USERS_DECOMPOSEDS3_REGION` | `eu-west-1` |
| `STORAGE_USERS_DECOMPOSEDS3_BUCKET` | `opencloud-blobs` |
| `STORAGE_USERS_DECOMPOSEDS3_ACCESS_KEY` | from `Secret opencloud-secrets`, key `s3-access-key` |
| `STORAGE_USERS_DECOMPOSEDS3_SECRET_KEY` | from `Secret opencloud-secrets`, key `s3-secret-key` |

The endpoint is deliberately `http`, not `https`: the listener at `192.168.0.6:9000` serves
plain HTTP and the transport is already encrypted by WireGuard. Same reasoning recorded at
`apply/50-apps/ocis/ocis.yaml:370-375`.

## Region is pinned, not discovered

`New()` passes `Region:` straight to minio-go, so `GetBucketLocation` is never called and the
configured region must equal what the server reports in `X-Amz-Bucket-Region`. A wrong region
does not look like a permissions error — it looks like a `307` or a redirect loop. Check it
before debugging the policy:

```sh
curl -sI http://192.168.0.6:9000/opencloud-blobs | grep -i x-amz-bucket-region
```

The same trap is already recorded for the Postgres backup bucket in
`docs/superpowers/plans/2026-10-03-titan-authentik-cnpg.md`. If you ever remove the explicit
region, add `s3:GetBucketLocation` on the bucket ARN — but fix the region instead.

Verified for `opencloud-blobs`: the server answers `X-Amz-Bucket-Region: eu-west-1` and
`STORAGE_USERS_DECOMPOSEDS3_REGION` is `eu-west-1`. They agree, so the pin is right. `GetBucketLocation`
itself is deliberately not granted — the driver never calls it, and the header can be read
unauthenticated with `curl -sI http://192.168.0.6:9000/opencloud-blobs`.

## One thing this key cannot do, on purpose

`ListMultipartUploads` is denied. The driver never calls it — `blobstore.go` has no such call — so
nothing in OpenCloud needs it. What it buys is the operator's ability to enumerate and clean up
abandoned multipart uploads, which is a real storage leak when an upload dies partway.

The oCIS policy this one replaced granted it. It was dropped for least privilege rather than by
oversight, and it is a judgement call rather than a rule: add `s3:ListBucketMultipartUploads` on the
bucket ARN if you would rather be able to see those uploads than save one action. Without it an
abandoned upload is invisible to this key and only shows up in an admin's bucket inventory.

## 3. Getting the credential into the repo

`apply/10-secrets/opencloud-secrets.yaml` holds every OpenCloud and Collabora secret, sops-encrypted
with the `titan-k8s` cluster key, minted by `scripts/setup-opencloud-secrets.sh`. The staging flow is
the one in `docs/ovh-dns-credential.md` §2 — plaintext at a git-ignored name under
`apply/10-secrets/`, `sops --encrypt --in-place`, then rename, because sops chooses recipients from
the file's own path.

## Rotation

```sh
mc admin user svcacct rm local <access-key>
mc admin user svcacct add local <parent-user>
```

Then re-stage the Secret and `flux reconcile kustomization secrets`. Anything still holding the
old key fails uploads immediately — loud, which is what you want from a rotation.

**If a key is ever pasted into a chat, a transcript or a ticket, rotate it rather than
deciding it is probably fine.** This repo has done exactly that once, for the S3 backup key;
the deletion of the superseded key in IAM is the only proof the rotation took, because
anything still using the old one would have stopped archiving.

**The current `opencloud` key is the exception, and a knowing one.** It was printed in full into
an agent transcript while being staged. The operator chose not to rotate: the MinIO listener is
reachable on the WireGuard mesh only, the key is scoped to one bucket, and the transcript is
being deleted. Recorded so whoever rotates it next is not guessing why the guidance above and
the live key disagree.
