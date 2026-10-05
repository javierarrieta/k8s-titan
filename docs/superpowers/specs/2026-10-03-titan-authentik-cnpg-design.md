# titan — authentik as the shared identity provider, on CloudNativePG

- **Date:** 2026-10-03
- **Status:** approved design — implementation plan to follow
- **Repo:** `javierarrieta/k8s-titan` (public)
- **Cluster:** `titan` — single-node k3s on OVH bare metal, NixOS-managed, live and green
- **Builds on:** `2026-10-03-k8s-titan-flux-bootstrap-design.md` (the bootstrap spec). That document
  stays authoritative for stages, sops, the age key and the certificate path; this one adds the
  first workload and **supersedes two of its decisions** (§11).

---

## 0. Ground rules carried forward

Everything in bootstrap spec §0 applies unchanged: this repo is public, so no credentials and no
concrete public IPv4 — write `<OVH_PUBLIC_IP>`. RFC1918 is used freely below — `10.62.0.0/16`,
titan's pod CIDR — and sits inside `make leak-check`'s allow-list.

An **AWS account ID is not a credential but is not secret either**, and this design publishes one:
the backup bucket's name embeds `562256260016`, and the bucket name must appear in the
`Cluster` manifest. It will not trip `leak-check`, and an account ID already appears in any ARN
anywhere it has ever been pasted. Recorded here because the alternative — renaming the bucket — gets
more expensive the moment backups exist, not after.

Secrets follow the same rule: `apply/10-secrets/` only, sops-encrypted, never plaintext anywhere
else. `make secrets-placement` enforces it.

---

## 1. Intent and success criteria

**Intent.** titan becomes the identity provider that eventually fronts all three clusters. This
spec delivers the first, self-contained slice of that: a working authentik on titan, on a
Postgres instance that every future titan workload can share.

Success looks like:

1. `https://auth.titan.arrieta.eu/` serves a real Let's Encrypt certificate off the existing
   wildcard, and a fresh admin can be created through authentik's first-run flow.
2. One shared Postgres cluster exists, and **adding the next database is a pull request, not a
   `psql` session** — declarative `Database` and `DatabaseRole` objects, which is the whole reason
   for using an operator.
3. The database is backed up to AWS S3 continuously, and **the restore has actually been performed
   once** (§7.4). A backup that has only ever been written is a hope.
4. The wildcard TLS secret reaches a second namespace without hand-copied certificates.
5. Nothing here requires cluster access to validate before merge — the existing offline gates still
   catch a broken manifest on the laptop.

**Explicitly out of scope** — named so they are not silently dropped (§12): PV backups as a general
restic stream, importing users and groups from the existing instances, cutting casa's and
techdelivery's apps over to titan's IdP, retiring those two instances, and monitoring.

---

## 2. Context this design inherits

| Source | What it settles |
|---|---|
| bootstrap spec §3, §4 | Stage graph, `dependsOn` chain, `wait: true` on `infra`, one file per stage, explicit `kustomization.yaml` per stage dir |
| bootstrap spec §5 | The `titan-k8s` age key, `.sops.yaml` recipients, the staging flow for new secrets |
| bootstrap spec §7, §9 | The wildcard `Certificate`, and the two deferred items this spec promotes |
| `nixos-configurations` `hosts/titan/disko.nix` | `nvme0`+`nvme1` → mdadm RAID1 → LVM `vg0` → `root` 150 G ext4 (`/`) and `pvc` 240 G ext4 (`/var/lib/rancher/k3s/storage`) |
| `nixos-configurations` `hosts/titan/configuration.nix` | etcd snapshots ship to MinIO over `wg_titan` with a staleness monitor. **That path is unchanged by this spec** — see §7.6 on why titan ends up with two backup destinations |
| live titan cluster | All five stages `Ready=True`, `titan-wildcard` `Ready=True`, `local-path` default SC with `reclaimPolicy: Delete` and `allowVolumeExpansion: false`, **zero PVCs**, zero Ingresses |
| `k8s-techdelivery` | `apply/50-apps/auth/authentik.yaml` (the closer template: ClusterIP + Ingress, no `nodeSelector`), `apply/20-infra/reflector.yaml`, `apply/50-apps/certificates/*.yaml` (the reflector annotation pattern), `scripts/restore-drill.sh` |
| `k8s-casa` | `apply/50-apps/auth/authentik.yaml` at chart `2026.8.3`, `apply/50-apps/casa/postgres-backup.yaml` (the `pg_dump` CronJob shape this spec replaces) |

### 2.1 Two sibling facts that are now stale

Both siblings carry `redis: enabled: false` in their authentik values. **authentik removed Redis
entirely in 2025.10** — caching, task queue and WebSocket connections all moved to Postgres.
Verified against chart `2026.8.3` directly: no `redis` key in `values.yaml`, no `redis` reference
in `templates/`, and `Chart.yaml` dependencies are only the Bitnami Postgres subchart (which now
defaults to `enabled: false`) and the `authentik-remote-cluster` ServiceAccount chart.

So titan deploys **no Redis**. The `redis: enabled: false` line in the siblings is a dead key and
is not copied. Casa's redis serves n8n and open-webui, not authentik.

The same reading shows `postgresql.enabled: false` is now the chart default; it is still written
explicitly, because a default that a future chart version may flip is not a decision.

---

## 3. Program decomposition — what this spec is one slice of

"Titan takes over the other two" is not one spec. Each row below gets its own spec → plan →
implementation cycle; only row 1 is in scope here.

| # | Sub-project | Depends on | Status |
|---|---|---|---|
| 1 | authentik + shared Postgres + backup path on titan | — | **this spec** |
| 2 | General PV backups (restic → object store, `30-backup` stage) | — | deferred, §12 |
| 3 | Populate titan's authentik with users and groups | 1 | deferred, §12.1 — mechanism undecided |
| 4 | Per-cluster outpost cutover: casa's and techdelivery's apps → titan's IdP | 3 | deferred |
| 5 | Retire the two old authentik instances | 4 | deferred |

**The seed decision, made and recorded.** One Postgres database *is* one authentik's entire
configuration and user directory, and there is no tool that merges two authentik databases. So one
of the three instances had to be the seed. Chosen: **neither — titan starts empty.** Providers and
applications get rebuilt deliberately rather than inherited, which is the only option consistent
with this repo's premise that a from-scratch cluster should be rebuildable from git alone.

Consequence carried into §12.1: because nothing is restored, no version pin is forced. titan takes
the current chart. Had a database been restored, the pin would have been forced — authentik
supports restore **only into the same version the backup was taken from**, and does not support
downgrading, and the two siblings are pinned apart (`2026.5.2` vs `2026.8.3`).

---

## 4. Decisions and rejected alternatives

| Alt | Decision | Choice | Why not the alternative |
|---|---|---|---|
| A1 | Postgres provisioning | **CloudNativePG** `0.29.1` / operator `1.30.1` | Zalando's `postgres-operator` and Crunchy PGO declare users *inside* the cluster CR, so every app edit touches the shared cluster object — the coupling the operator exists to remove. A plain Deployment + `POSTGRES_*` env (both siblings) has a trap: the image runs `/docker-entrypoint-initdb.d` **only on the first initdb**, so "create the next database" is a one-time imperative step that silently does nothing on an existing volume. |
| A2 | Declarative databases and roles | CNPG `Database` + `DatabaseRole` CRDs | These are the only ones where a role is a standalone object with its own lifecycle and status, which is what lets an app's manifest carry its own database next to it. |
| A3 | IdP database | one `Database` + one `DatabaseRole` for authentik, authored next to the app | A single shared `authentik` DB inside one superuser would work and is less YAML; it also means every future workload shares one permission set. |
| A4 | Role password | **authored by the operator**, shipped sops-encrypted, referenced via `passwordSecret` | Letting CNPG generate it puts the Secret in `databases` under operator ownership, needing Reflector to mirror a Secret we cannot annotate — the operator rewrites it. Authoring it puts the credential in `apply/10-secrets` like every other credential here. |
| A5 | Cross-namespace TLS | **promote Reflector** (`10.0.46`) + move the `Certificate` to a `certificates` namespace | A second `Certificate` for the same wildcard doubles ACME renewals for nothing. Traefik's `TLSOption` cross-namespace reference needs Traefik CRDs and per-route config the Helm chart does not emit. Hand-copying the Secret is the thing that rots. |
| A6 | Database backup | CNPG `barmanObjectStore` + `ScheduledBackup` → **AWS S3** | The hand-written `pg_dump` CronJob (casa's shape) yields one restore point a day, needs an image to pin and a `.pgpass` assembled in a shell string, and needs a backup PVC. Barman gives base backups **plus WAL archives** — point-in-time recovery — in less YAML. |
| A7 | General PVC backups | **deferred, consciously overriding bootstrap spec §9's trigger** | §9 said "before any workload with data lands on titan", and an IdP is data. The override is accepted because the database has its own backup path and the restic stream stays deferred with its trigger intact. Recorded in §11 so it is not mistaken for an oversight. |
| A8 | Storage class | keep `local-path` | See §6.4: the requested size is not enforced by anything, so switching classes buys enforcement only at the cost of a second storage system on a single node. The real boundary is the LVM volume, and it is growable. |
| A9 | Redis | **not deployed** | §2.1. authentik 2025.10 removed it. |
| A10 | authentik config as code | not in this slice | Blueprints are the right long-term answer and they are the mechanism sub-project 3 needs; adding them now would be speculative until the import mechanism is chosen. |

---

## 5. Architecture

### 5.1 New namespaces

Added to `apply/00-bootstrap/namespaces.yaml`, which remains the only place namespaces are
created (bootstrap spec §4):

| namespace | holds |
|---|---|
| `certificates` | the wildcard `Certificate`; the source of `titan-tls` |
| `databases` | the CNPG `Cluster`, its `Database`/`DatabaseRole` objects, `ScheduledBackup`, backup credentials |
| `auth` | the authentik `HelmRelease`, its values Secret, a reflected copy of `titan-tls` |
| `cnpg-system` | the CloudNativePG operator |

### 5.2 New and changed files

```
apply/00-bootstrap/namespaces.yaml              + 4 namespaces
apply/20-infra/reflector/reflector.yaml         HelmRepository emberstack + HelmRelease reflector 10.0.46   (ns apps)
apply/20-infra/cnpg/operator.yaml               OCIRepository + HelmRelease cloudnative-pg 0.29.1              (ns cnpg-system)
apply/20-infra/kustomization.yaml               + the two new files
apply/40-certificates/titan-wildcard.yaml       MOVED to ns certificates, + secretTemplate reflector annotations
apply/50-apps/databases/postgres.yaml           CNPG Cluster                                                    (ns databases)
apply/50-apps/databases/postgres-backup.yaml    ScheduledBackup                                                 (ns databases)
apply/50-apps/auth/authentik.yaml               HelmRepository + HelmRelease authentik 2026.8.3               (ns auth)
apply/50-apps/auth/authentik-db.yaml            Database + DatabaseRole                                         (ns databases)
apply/50-apps/kustomization.yaml                + the four new files
apply/10-secrets/authentik-secrets.yaml         sops
apply/10-secrets/s3-backup-secrets.yaml         sops
apply/10-secrets/kustomization.yaml             + the two new files
scripts/restore-drill.sh                        the §7.4 drill
Makefile                                        + release-secrets gate (§10.1)
docs/authentik-runbook.md                       first admin, restore drill, do-not-rotate notes
```

Both operators go in `20-infra` beside cert-manager, so the existing `dependsOn` chain orders them
for free: `infra` carries `wait: true`, so it does not report `Ready` until the CNPG operator and
Reflector are `Ready`, and `certificates` and `apps` stay blocked behind it. That is bootstrap
spec §3's stated philosophy — fail loudly rather than apply into a half-built cluster — inherited
at no cost. The honest price is the same one already paid: if the CNPG operator fails to become
Ready, nothing downstream deploys at all.

### 5.3 The certificate move, and why now is the only free moment

`titan-wildcard` lives in `apps` today because bootstrap spec §7 had no other way to get its Secret
where an Ingress could read it. **Nothing consumes `titan-tls` yet** — `apply/50-apps` is empty, so
there is not one Ingress pointing at it.

Moving the `Certificate` to `certificates` means Flux creates the new object and prunes the old;
deleting the old `Certificate` deletes `apps/titan-tls`; Reflector repopulates it via
auto-reflection within the same reconcile. The window is one reconcile and there is no traffic to
break. Performing this same move after ten services sit behind that certificate is a live TLS
cutover with a real breakage window.

This is bootstrap spec §9's deferred item — "Reflector operator + a `certificates` namespace" —
promoted on its own stated trigger ("a second namespace needs `titan-tls`"), and promoted whole
rather than half: the namespace moves too, so `apps` stops being the cluster's certificate source
by accident.

Reflector's scope is deliberately narrow: **it replicates TLS material and nothing else.** The
database credential is authored instead (§4 A4).

---

## 6. Database layer

### 6.1 Operator

`HelmRelease cloudnative-pg` `0.29.1` (operator `1.30.1`) in `cnpg-system`, from
`https://cloudnative-pg.github.io/charts`. Requires Kubernetes ≥ 1.29; titan runs `v1.35.8+k3s1`.
Operator `1.30.x` supports Postgres 14–18.

CRDs ship in the chart's `templates/crds/` and are installed on first install. The HelmRelease
sets `install.crds: CreateReplace` and `upgrade.crds: CreateReplace`, matching the cert-manager
release's treatment in this repo, so a CRD update is not silently skipped on upgrade.

### 6.2 The shared cluster

```yaml
apiVersion: postgresql.cnpg.io/v1
kind: Cluster
metadata:
  name: postgres
  namespace: databases
  annotations:
    kustomize.toolkit.fluxcd.io/prune: disabled   # §6.3
spec:
  instances: 1
  imageName: ghcr.io/cloudnative-pg/postgresql:18.6
  storage:
    size: 10Gi          # a label, not a limit — §6.4
    storageClass: local-path
  resources:
    requests: {cpu: 100m, memory: 256Mi}
    limits:   {cpu: "1",  memory: 1Gi}
  backup:                       # the barmanObjectStore block — see §7.1 for the real content
```

One instance on one node is the normal shape, not a compromise: there is no second node to place a
replica on, and a `minSyncReplicas` of anything above zero would be unsatisfiable.

`imageName` is pinned explicitly rather than inherited from the operator default, so a later
`flux` bump of the operator cannot silently move the Postgres major version. `18.6` is verified, not
guessed: a manifest fetch against GHCR returns `200` for `18.6` and `404` for `18.5`, `18.7` and
`99.9`, so `18.6` is the published 18.x at the time of writing. Operator `1.30.x` supports Postgres
14–18, so this is inside the supported band.

Sizing is deliberately modest: this node also runs etcd, the API server, Traefik and Flux, and
Postgres is a handful of small databases, not a warehouse. No CPU or memory figure in this spec is
a measurement — they are starting values to be revised once monitoring exists.

### 6.3 The GitOps hazard: deleting the YAML deletes the database

CNPG deletes a Cluster's PVCs when the `Cluster` object is deleted. The `apps` stage runs with
`prune: true`. Therefore **removing `postgres.yaml` from git — a bad rebase, a mis-scoped revert, a
`git rm` during a reorganisation — destroys the identity database of every service that will ever
depend on it.**

Mitigation: `kustomize.toolkit.fluxcd.io/prune: disabled` on the `Cluster`, which exempts that one
object from Flux pruning while leaving the other 40-apps manifests prunable normally. Deleting the
database then requires an explicit, deliberate `kubectl delete cluster postgres`.

There is no per-cluster field that stops CNPG itself from removing PVCs — no `requirePVC` exists in
the `1.30` CRD (checked against the shipped CRD, not the docs). The remaining options are
`reclaimPolicy: Retain` on the StorageClass, which is cluster-wide and owned by k3s' own manifests
and therefore `nixos-configurations` territory, and `kubectl cnpg destroy --keep-pvc`, which is
procedural. The annotation is the part that can live in git, so it lives in git.

### 6.4 What the PVC size actually means on this cluster

`local-path-provisioner`'s own README: *"No support for the volume capacity limit currently. The
capacity limit will be ignored."* The requested size is written onto the PV and PVC objects and
reported by `kubectl get pvc`; nothing enforces it, and a pod will write past it. Upstream issue
#345 is this exact gap, and PR #350 — which added resize bookkeeping — describes itself as having
*"no effect on the underlying volume"*, only fixing reported status.

Growing through Kubernetes is not available either, which is why k3s ships `local-path` with
`allowVolumeExpansion: false`. Upstream issue #107 records what happens if you flip it: the PVC
edit succeeds and nothing changes. There is nothing to expand, because the volume is a directory on
a shared filesystem that already has all the space there is.

**The real boundary is LVM, and it is growable.** From `hosts/titan/disko.nix`:

```
nvme0 + nvme1 → mdadm RAID1 "titan" → LVM vg0
  ├─ root  150G  ext4  /                                ← etcd, API server, everything
  └─ pvc   240G  ext4  /var/lib/rancher/k3s/storage    ← every PVC, including this one
```

The ceiling for all PVCs combined is that 240 G filesystem. ext4 on LVM grows online — `lvextend`
then `resize2fs`, no unmount, no downtime — subject to free extents in `vg0`, which is a `vgs` /
`lvs` on the host. The change belongs to `nixos-configurations` (`lvs.pvc.size` in disko), not to
this repo. Growing is routine; shrinking ext4 is the direction that causes damage, so nothing here
is planned in that direction.

Two consequences written down because they are load-bearing:

1. The `10Gi` request is **documentation, not a guard rail**, and carries a comment saying so, so
   nobody later mistakes it for a limit. The reason that is survivable is the partitioning: etcd
   and the API server live on `root`, so a runaway Postgres fills `vg0/pvc` and takes down the
   workloads on it while the control plane keeps its own filesystem.
2. The missing piece is *alerting on the real boundary* — free space on `/var/lib/rancher/k3s/storage`.
   There is no Prometheus on titan. §11 sharpens the deferred-monitoring trigger accordingly, and
   until monitoring lands the honest position is accepted risk with a named failure mode (§7.5).

### 6.5 Declarative per-app databases

```yaml
# apply/50-apps/auth/authentik-db.yaml — namespace: databases, because CNPG requires the
# Database/DatabaseRole to share the Cluster's namespace
apiVersion: postgresql.cnpg.io/v1
kind: Database
spec:
  name: authentik
  owner: authentik
  cluster: {name: postgres}
---
apiVersion: postgresql.cnpg.io/v1
kind: DatabaseRole
spec:
  name: authentik
  cluster: {name: postgres}
  login: true
  passwordSecret: {name: authentik-db-credentials}
```

Field names verified against the shipped `1.30` CRDs, not against prose:

- `DatabaseRole` has **no `managePassword` field**. Referencing a pre-existing Secret is done with
  `passwordSecret`; `disablePassword` is the separate "set the password to NULL" switch, and the
  CRD's CEL rule makes `passwordSecret` and `disablePassword` mutually exclusive.
- The referenced Secret must be `type: kubernetes.io/basic-auth` carrying `username` and
  `password`, labelled `cnpg.io/reload: "true"` so a rotation is applied without a restart.
- `DatabaseRole` names are validated against `postgres`, `streaming_replica`, `pg_*` and `cnpg_*`.
  `authentik` is fine.
- Both objects' `cluster.name` is immutable after creation (CEL `self == oldSelf`), so retargeting
  a database to a different cluster means deleting and recreating the CR — worth knowing before
  someone tries it in a hurry.

The pattern for the next workload that needs a database is one file next to its manifest, and no
imperative step anywhere.

---

## 7. Backup and restore

### 7.1 Object store

On the `Cluster`:

```yaml
spec:
  backup:
    barmanObjectStore:
      destinationPath: s3://k8s-titan-pg-562256260016-eu-west-1-an
      s3Credentials:
        accessKeyId:     {name: s3-backup-secrets, key: ACCESS_KEY_ID}
        secretAccessKey: {name: s3-backup-secrets, key: SECRET_ACCESS_KEY}
        region:          {name: s3-backup-secrets, key: AWS_REGION}
    # CORRECTED during implementation: retentionPolicy is a child of spec.backup, not of
    # barmanObjectStore. Nested one level deep it made the API server reject the whole
    # Cluster with "field not declared in schema", failing the dry-run and blocking the
    # entire apps stage. The CRD's spec.backup.properties are barmanObjectStore,
    # retentionPolicy, target, volumeSnapshot.
    retentionPolicy: 30d
```

Three things this gets right that a first draft got wrong:

- **No `endpointURL`.** Setting one is what you do for an S3-compatible store. Against real AWS it is
  at best redundant and at worst a second thing to get wrong.
- **Region lives in the Secret.** `s3Credentials.region` is a secret-key reference in the CRD — *"the
  reference to the secret containing the region name"* — not a plain field. There is no EC2 instance
  metadata on titan for barman to fall back to, so the region is required, not optional.
- **The region is `eu-west-1`, and that was verified, not assumed.** The bucket name says
  `eu-west-1`; the operator initially said `us-west-1`. `curl -I` on the bucket returns
  `x-amz-bucket-region: eu-west-1` and a 307 redirect, and a bucket cannot be used from another
  region. A wrong region here does not fail loudly: every WAL archive fails behind a redirect while
  Postgres reports itself healthy, which is precisely the §7.5 failure. Check the bucket's region the
  same way rather than trusting a name or a memory.

`retentionPolicy` is the CRD's own pattern `^[1-9][0-9]*[dwm]$` — **`30d`, not `30 days`**. CNPG
enforces it internally via `barman-cloud-backup-delete --retention-policy "RECOVERY WINDOW OF 30 DAYS"`,
using the same credentials as everything else. It is the thing that stops the bucket growing forever,
and the easiest thing to forget. An S3 lifecycle rule is a **backstop for noncurrent versions, not
retention**; do not let anyone later "consolidate" the two and lose retention.

WAL archiving is on by default once a `barmanObjectStore` exists, so archiving is continuous and the
`ScheduledBackup` below is only the daily base backup.

### 7.2 Schedule

```yaml
apiVersion: postgresql.cnpg.io/v1
kind: ScheduledBackup
metadata:
  name: postgres-daily
  namespace: databases
spec:
  schedule: "0 0 3 * * *"
  method: barmanObjectStore
  backupOwnerReference: cluster
  cluster: {name: postgres}
```

**Corrected during implementation; the original text here was wrong in two ways, both silent.**

The schedule was `"0 3 * * *"`. CNPG pins `robfig/cron` v1.2.0, whose default parser is
`Second|Minute|Hour|Dom|Month|DowOptional` — the optional field is the day of week at the *end*, not
seconds at the front. Five fields therefore parse as second 0, minute 3, every hour: 24 base backups a
day, not one at 03:00. Verified by running v1.2.0. The CRD sets no pattern on `spec.schedule` and the
admission webhook only warns — the object is admitted, the Flux reconcile stays green, and the
warning reaches only the kustomize-controller log — so nothing stops it.

`backupOwnerReference: self` was justified as keeping pruning from taking the backups. Owner
references cascade, so `self` is precisely the value under which deleting the `ScheduledBackup`
garbage-collects every `Backup` it produced. `cluster` ties them to the `Cluster`, which carries
`kustomize.toolkit.fluxcd.io/prune: disabled`.

### 7.3 Credentials: a dedicated IAM user, and one lesson already paid for

`s3-backup-secrets` in `databases` carries `ACCESS_KEY_ID`, `SECRET_ACCESS_KEY` and `AWS_REGION` for
a **dedicated IAM user** (`k8s-titan-pg-backups`) whose policy grants only this bucket.

Deliberately not the host's `titan/minio_env` credentials. That is bootstrap spec §5.1's argument
applied one layer down: the credential that writes backups must not be the credential that can read
everything else. On MinIO that separation was a policy on a shared server; on AWS it is an IAM
boundary, which is the stronger version of the same idea — the key that writes this bucket cannot
read casa's restic repositories or titan's etcd snapshots, because those are not in its policy.

**IAM user policy** — the set `barman-cloud-wal-archive`, `barman-cloud-backup` and
`barman-cloud-backup-delete` need. `DeleteObject` is present because `retentionPolicy` deletes
through the same credentials:

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "BarmanObjectAccess",
      "Effect": "Allow",
      "Action": [
        "s3:GetObject", "s3:PutObject", "s3:DeleteObject",
        "s3:ListMultipartUploadParts", "s3:AbortMultipartUpload"
      ],
      "Resource": "arn:aws:s3:::k8s-titan-pg-562256260016-eu-west-1-an/*"
    },
    {
      "Sid": "BarmanBucketListing",
      "Effect": "Allow",
      "Action": ["s3:ListBucket", "s3:GetBucketLocation"],
      "Resource": "arn:aws:s3:::k8s-titan-pg-562256260016-eu-west-1-an"
    }
  ]
}
```

Narrowing to the `postgres/` prefix (CNPG's barman `serverName` defaults to the cluster name) is worth
doing **after** the drill has proven the access pattern. Narrowing a working policy is easy;
debugging an over-narrow one at 3 a.m. is not.

**Bucket policy — and the mistake this design had to make first.** The obvious shape, *deny everyone
except the backup user*, is a lockout waiting to happen, and it happened:

```json
"Condition": { "ArnNotLike": { "aws:PrincipalArn": "arn:aws:iam::562256260016:user/k8s-titan-pg-backups" } }
```

A resource-based policy has **no implicit owner exemption**. An explicit `Deny` with `Principal: "*"`
applies to the account root as well — `aws:PrincipalArn` for root is `arn:aws:iam::ACCOUNT:root`,
which is not the whitelisted ARN — so root is denied `s3:PutBucketPolicy`, the only call that could
undo the policy. The recovery is an AWS Support case; there is no CLI workaround, because every call
that could replace the policy is the call being denied.

The correct deny scopes to **outsiders**, which structurally cannot lock out your own identities — and
where the list *is* narrowed to one principal, **root must be in that list**. `ArnNotLike` takes a list
and a list is an OR: if the principal matches any entry, the Deny does not apply.

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "DenyInsecureTransport",
      "Effect": "Deny", "Principal": "*", "Action": "s3:*",
      "Resource": [
        "arn:aws:s3:::k8s-titan-pg-562256260016-eu-west-1-an",
        "arn:aws:s3:::k8s-titan-pg-562256260016-eu-west-1-an/*"
      ],
      "Condition": { "Bool": { "aws:SecureTransport": "false" } }
    },
    {
      "Sid": "DenyForeignPrincipals",
      "Effect": "Deny", "Principal": "*", "Action": "s3:*",
      "Resource": [
        "arn:aws:s3:::k8s-titan-pg-562256260016-eu-west-1-an",
        "arn:aws:s3:::k8s-titan-pg-562256260016-eu-west-1-an/*"
      ],
      "Condition": { "StringNotEquals": { "aws:PrincipalAccount": "562256260016" } }
    },
    {
      "Sid": "DenyAnyoneNotRootOrBackupUser",
      "Effect": "Deny", "Principal": "*", "Action": "s3:*",
      "Resource": [
        "arn:aws:s3:::k8s-titan-pg-562256260016-eu-west-1-an",
        "arn:aws:s3:::k8s-titan-pg-562256260016-eu-west-1-an/*"
      ],
      "Condition": {
        "ArnNotLike": {
          "aws:PrincipalArn": [
            "arn:aws:iam::562256260016:root",
            "arn:aws:iam::562256260016:user/k8s-titan-pg-backups"
          ]
        }
      }
    }
  ]
}
```

Statements 1 and 2 are safe by construction — `aws:PrincipalAccount` scopes the deny to outsiders and
can never touch root, admin roles, or the backup user. Statement 3 is the optional narrowing, and it
carries the lockout risk in every future edit, so three rules about it:

- **root is in the list, always.** With root whitelisted, `aws s3api delete-bucket-policy` is a
  permanent escape hatch. Without it there is none.
- **If administration ever moves to Identity Center or an assumed role, add `role/*` to the list
  first.** An assumed role's `aws:PrincipalArn` is `arn:aws:iam::ACCOUNT:role/<name>`, not `:root`,
  so the same mistake repeats.
- The narrowing is **already** enforced by the IAM user policy, which grants only this bucket and
  cannot lock anyone out because it grants rather than denies. Statement 3 is defence in depth
  against a future permissive policy elsewhere in the account — not the primary control.

Anonymous access needs no statement at all: a policy of only Denys grants nothing, and cross-account
access requires an explicit Allow somewhere. Statements 1–2 are backstops against a future mistake.

Two further bucket rules:

- **Do not** add a "require the `x-amz-server-side-encryption` header" statement. barman does not
  send that header — it relies on bucket default encryption — so such a rule rejects every upload
  from the database while looking like good hygiene.
- Block Public Access all four on, default encryption SSE-S3, versioning on with a lifecycle rule
  expiring noncurrent versions at 35 days (backstop only, per §7.1).

### 7.4 The restore drill

CNPG recovery is **never in-place**: it bootstraps a *new* cluster from a base backup and replays
WAL (`bootstrap.recovery`, optionally with a `recoveryTarget`). So the drill is a scratch cluster,
not a restore over a running one:

1. Apply a scratch `Cluster postgres-drill` in `databases` with `bootstrap.recovery` from the
   object store, target latest.
2. Wait for `Healthy`. `pg_dump` the `authentik` database out of it and assert the marker —
   `SELECT count(*) FROM auth_user` plus one row created immediately before the backup.
3. Delete the scratch Cluster and its PVC.

`scripts/restore-drill.sh` automates it, mirroring `k8s-techdelivery/scripts/restore-drill.sh`.
The precedent is this repo's own lesson: the etcd snapshot in `nixos-configurations` failed silently
for four nights because the *manual* drill inherited credentials from the operator's shell while
the scheduled unit never received them. Running the drill once, on the record, is part of this
slice's definition of done.

Cost: the drill needs a second 10 Gi PVC on the same 240 G LV. Fine — and further evidence that the
size label is fiction.

### 7.5 The failure mode that turns into slow disk fill

If the object store becomes unreachable, `barman-cloud-wal-archive` fails and Postgres **retains WAL
segments on the PVC** instead of shipping them. The database keeps running and reports itself healthy
while `pg_wal` grows until `vg0/pvc` is gone — which takes every PVC on that volume down with it.

Moving to AWS removed one trigger and left the shape intact. The path no longer depends on `wg_titan`
— a mesh outage can no longer stop backups — but it now depends on public egress, on an IAM key that
**can expire or be rotated without anyone telling the cluster**, and on the region being right (§7.1).

Nothing in the current tree would notice. There is no Prometheus on titan, and the existing
`k3sSnapshotMonitor` watches a different bucket on a different host and a different provider. This is
recorded as accepted risk with a named trigger in §11, not as covered.

### 7.6 Two backup destinations, deliberately

After this spec titan ships backups to two places:

| stream | destination | owned by |
|---|---|---|
| etcd snapshots (`titan-etcd`) | casa's MinIO over `wg_titan` | `nixos-configurations` |
| Postgres base backups + WAL | AWS S3, this spec | this repo |

That is not an inconsistency to be tidied away. The etcd stream exists because k3s' own
`--etcd-s3-*` flags write it and it must be configured where k3s is configured; moving it is a
`nixos-configurations` change with its own risk, and this slice has no business bundling it. What
matters is that nobody discovers, during a restore, that the two streams live in different clouds and
require different credentials to find.

---

## 8. authentik layer

`HelmRelease authentik` chart `2026.8.3` in `auth`, server + worker, `ClusterIP`.

### 8.1 The values split

Non-secret configuration stays plaintext in the HelmRelease so it is reviewable in a diff:

```yaml
values:
  authentik:
    listen:
      trusted_proxy_cidrs: 10.62.0.0/16      # → AUTHENTIK_LISTEN__TRUSTED_PROXY_CIDRS
    web:
      base_url: https://auth.titan.arrieta.eu/  # → AUTHENTIK_WEB__BASE_URL
    postgresql:
      host: postgres-rw.databases.svc.cluster.local
      name: authentik
      user: authentik
      # password intentionally empty — supplied via envFrom
    error_reporting:
      enabled: true
  global:
    envFrom:
      - secretRef: {name: authentik-secrets}
  postgresql:
    enabled: false
  server:
    service: {type: ClusterIP}
    ingress:
      enabled: true
      ingressClassName: traefik
      hosts: [auth.titan.arrieta.eu]
      tls:
        - secretName: titan-tls
          hosts: [auth.titan.arrieta.eu]
  prometheus:
    rules: {enabled: false}
```

The two settings above are written in the chart's nested form, not as raw `env` entries. The chart's
`authentik.env` helper flattens `authentik.<section>.<key>` into `AUTHENTIK_<SECTION>__<KEY>`, upper-
casing both halves — which is how the chart's own `authentik.web.path` becomes `AUTHENTIK_WEB__PATH`.
Note that `env:` and `envFrom:` live under `global:` in this chart (values.yaml lines 114 and 130,
with `authentik:` starting at line 151); there is no `authentik.env`. Writing them at `authentik.env`
would be silently ignored.

Secrets arrive as environment variables through `global.envFrom`, from one sops Secret holding
`AUTHENTIK_SECRET_KEY` and `AUTHENTIK_POSTGRESQL__PASSWORD`.

This avoids the siblings' pattern of hiding an entire `values.yaml` inside one encrypted blob. It
works because of a detail checked in the chart's `authentik.env` helper: it **omits empty values**
(`(ne $v "\"\"")`), so leaving `password: ""` in values means the chart-generated Secret never
defines `AUTHENTIK_POSTGRESQL__PASSWORD` at all, and there is no precedence contest between the
chart's Secret and our `envFrom`. The chart's `existingSecret` escape hatch was rejected for the
same reason the blob was: it discards every `authentik.*` value, including the non-secret ones.

`error_reporting: enabled: true` keeps parity with both siblings. It is opt-in anonymous telemetry
to sentry.beryju.org with `send_pii: false`. Flipping it to `false` is a one-line change and is not
a security finding either way.

### 8.2 Two 2026.8 settings that bite if skipped

- **`AUTHENTIK_LISTEN__TRUSTED_PROXY_CIDRS`.** 2026.8 "more strictly enforces trusted proxy
  configuration" as a breaking change: forwarded headers (`X-Forwarded-For`, `-Proto`, `-Host`)
  are honoured only from listed CIDRs. Traefik connects from the pod network, so titan's cluster
  CIDR `10.62.0.0/16` is the value. Get it wrong and HTTPS requests are interpreted as HTTP —
  blocked mixed content, an endless spinner, or authentication errors. The pod CIDR is broader than
  ideal (any pod could in principle forge the headers), which is the accepted cost of not pinning a
  stable Traefik address; the alternative is pinning a pod IP that changes.

  Two things about this setting that are easy to get wrong and were checked against the docs rather
  than assumed:

  - **The format is a comma-separated string, not a JSON list.** The chart key is
    `authentik.listen.trusted_proxy_cidrs`, a string, and authentik's own fix for env loading
    (goauthentik/authentik#8075) states the format is `127.0.0.0/8,::1/128` — explicitly *not*
    `["127.0.0.0/8","::1/128"]`. A JSON list here is silently not what was asked for.
  - **Setting it replaces the defaults**, which are `127.0.0.0/8`, `10.0.0.0/8`, `172.16.0.0/12`,
    `192.168.0.0/16`, `fe80::/10`, `::1/128`. titan's pod CIDR `10.62.0.0/16` already falls inside
    the default `10.0.0.0/8` — so **not setting this at all would work**. Setting it is a deliberate
    tightening, and it must therefore carry loopback with it: the value used is
    `10.62.0.0/16,127.0.0.0/8`, so that `kubectl port-forward` debugging still gets correct
    headers. Tightening to the pod network alone would break the local debugging path while looking
    like an improvement.
- **`AUTHENTIK_WEB__BASE_URL`.** Recommended now, **required in 2026.11**. Setting it now is free
  and removes a future upgrade surprise.

### 8.3 First admin

Created through the browser flow at `https://auth.titan.arrieta.eu/if/flow/initial-setup/` —
**trailing slash required**, `Not Found` without it. No admin password ever enters git.

`AUTHENTIK_BOOTSTRAP_PASSWORD` exists as an alternative and is deliberately not used: it puts a
plaintext password in a pod spec for no benefit here, since the first login is a human act anyway.

`AUTHENTIK_SECRET_KEY` signs cookies and derives unique user IDs; the chart's own comment says do
not change it after the first install. It lives in sops, and the sops file is its only backup.

### 8.4 TLS

The Ingress references `secretName: titan-tls` in `auth`, which does not exist natively — it is
Reflector's copy of the Secret produced by the `Certificate` in `certificates`. The `secretTemplate`
on the `Certificate` carries the four emberstack annotations, following
`k8s-techdelivery/apply/50-apps/certificates/*.yaml`:

```yaml
secretTemplate:
  annotations:
    reflector.v1.k8s.emberstack.com/reflection-allowed: "true"
    reflector.v1.k8s.emberstack.com/reflection-allowed-namespaces: "apps,auth"
    reflector.v1.k8s.emberstack.com/reflection-auto-enabled: "true"
    reflector.v1.k8s.emberstack.com/reflection-auto-namespaces: "apps,auth"
```

Auto-reflection means Reflector creates the destination Secret itself; no placeholder object is
maintained by hand. `apps` stays in both lists because it is the destination today and will hold
future workloads.

---

## 9. Secrets inventory and operator prerequisites

Both files match `.sops.yaml`'s `path_regex` and rely on its `encrypted_regex: ^(data|stringData)$`
so `metadata`, `apiVersion` and `kind` stay plaintext for review.

### 9.1 `apply/10-secrets/authentik-secrets.yaml`

| object | namespace | keys |
|---|---|---|
| `authentik-secrets` | `auth` | `AUTHENTIK_SECRET_KEY`, `AUTHENTIK_POSTGRESQL__PASSWORD` |
| `authentik-db-credentials` | `databases` | `username`, `password` — `type: kubernetes.io/basic-auth`, labelled `cnpg.io/reload: "true"` |

Two objects, same password. CNPG's `passwordSecret` must live in the Cluster's namespace; authentik
reads its env in `auth`. No mirroring, no operator-owned Secret to chase.

### 9.2 `apply/10-secrets/s3-backup-secrets.yaml`

`s3-backup-secrets` in `databases`: `ACCESS_KEY_ID`, `SECRET_ACCESS_KEY`, `AWS_REGION` (`eu-west-1`).

### 9.3 Prerequisites that must exist before merge

Otherwise the stages go red on first sync and a red object on a bootstrap is indistinguishable
from a broken one.

1. **In AWS:** the bucket `k8s-titan-pg-562256260016-eu-west-1-an` exists in `eu-west-1`; the IAM
   user `k8s-titan-pg-backups` carries the policy in §7.3 and an access key; the bucket policy is the
   three-statement form in §7.3 with **root whitelisted** — a principal-scoped deny without root in
   the list locks out the account owner; Block Public Access, default encryption and versioning set
   as §7.3 describes. Verify from
   the host before wiring the cluster to it:

```bash
aws s3 ls s3://k8s-titan-pg-562256260016-eu-west-1-an \
  --region eu-west-1 --no-verify-ssl 2>&1 | head   # expect a listing, not AccessDenied
aws s3api get-bucket-location --bucket k8s-titan-pg-562256260016-eu-west-1-an
```

   The second command is the region check. Trusting the bucket name, or a memory of it, is how §7.1's
   redirect failure happens.
2. **Generate the values locally** — `openssl rand -base64 32` for the secret key,
   `openssl rand -base64 24` for the passwords.
3. **Encrypt through the documented staging flow.** The gitignored name is what keeps
   `git add -A` from ever staging plaintext, and sops picks recipients from the file's own path:

```bash
export SOPS_AGE_KEY_FILE=$HOME/.config/sops/age/titan-k8s-key.txt
stage=apply/10-secrets/.staging.authentik.yaml
$EDITOR "$stage"                      # plaintext, git-ignored, matches path_regex
sops --encrypt --in-place "$stage"
mv "$stage" apply/10-secrets/authentik-secrets.yaml
make validate
```

4. **`SOPS_AGE_KEY_FILE` is not optional.** sops reads age identities from
   `~/.config/sops/age/keys.txt` and does not scan the directory; without the export,
   `make validate` prints a bare `FAILED:` that looks exactly like a corrupt secret.

---

## 10. Verification

### 10.1 Offline — one new gate

`make check` runs the existing four gates unchanged. `kustomize-check` builds every stage directory
that declares a `kustomization.yaml`, so each new file must be listed in its stage's
`kustomization.yaml` (AGENTS.md), and the existing stage-path assertion catches a declared-but-
missing directory.

**New gate, `make release-secrets`:** for every `HelmRelease` in the tree, every Secret named by
`spec.valuesFrom[].name`, `spec.values.global.envFrom[].secretRef.name`, or — if any release ever
starts using it — `spec.values.authentik.existingSecret.secretName`, must exist in
`apply/10-secrets` with a matching `metadata.namespace`. It fails when it finds zero HelmReleases,
so it cannot pass vacuously — the same rule `secrets-present` follows.

Rationale: today a typo'd Secret name is a red HelmRelease three time zones away, and moving
live-cluster failures onto the laptop is this repo's entire thesis. Its honest limit goes in the
Makefile comment: it proves a name and namespace exist in the tree, **not** that the keys inside
are the ones the chart wants.

Two assertions worth stating once so nobody "fixes" them later:

- The bucket name contains `562256260016`, an AWS account ID. It is an identifier, not a credential,
  it is required in the manifest, and it is not a leak — it must not be replaced with a placeholder.
- `10.62.0.0/16` in the trusted-proxy CIDR likewise.

### 10.2 Against the cluster

```bash
kubectl -n cnpg-system get helmrelease cloudnative-pg      # Ready
kubectl -n databases get cluster postgres                  # Healthy, 1/1 instances
kubectl -n databases get database,databaserole             # authentik synced
kubectl -n certificates get certificate titan-wildcard     # Ready
kubectl -n apps get secret titan-tls                       # reflected copy
kubectl -n auth get secret titan-tls                       # reflected copy
kubectl -n auth get helmrelease authentik                  # Ready; server + worker Running
kubectl -n databases get backup                            # completed
```

Then the human half:

1. `https://auth.titan.arrieta.eu/if/flow/initial-setup/` → create `akadmin`; log out; log back in.
   That login **is** the test for `AUTHENTIK_LISTEN__TRUSTED_PROXY_CIDRS` — a wrong CIDR produces a
   redirect loop or a mixed-content block, which is far louder than a silent failure.
2. Confirm objects actually landed in the bucket from outside the cluster — `aws s3 ls
   s3://k8s-titan-pg-562256260016-eu-west-1-an --region eu-west-1`, or the console. S3 failures are
   exactly the kind that produce no error anywhere; that is the lesson the etcd snapshot already paid
   for. Expect `postgres/base/` and `postgres/wals/` under the prefix.
3. Run `scripts/restore-drill.sh` end to end and record the output.

---

## 11. Amendments to the bootstrap spec

That spec is where this repo records *why*, so these are edits to it, not commentary alongside it.

1. **D10 is superseded.** New decision: Reflector promoted; the `Certificate` lives in namespace
   `certificates`; `titan-tls` is reflected into `apps` and `auth`. Record why now: §9's trigger
   fired, and moving while zero Ingresses consume the certificate is free (§5.3).
2. **§7 becomes false in two places** — *"No `secretTemplate` ships with titan's `Certificate`"* and
   *"Reflector is deferred"*. Rewrite both rather than delete them, so the reasoning trail survives
   the reversal.
3. **§9 rows.** Delete the Reflector row as promoted. Keep the PV-backup row, but record the
   conscious override: its trigger said "before any workload with data lands on titan", authentik is
   data, and the override is accepted because the database has its own backup path while the general
   restic stream stays deferred with its trigger intact.
4. **§9's monitoring row gets a sharper trigger.** "titan holds something worth alerting on" is now
   satisfied. The two metrics that matter are free space on `/var/lib/rancher/k3s/storage` — the
   real ceiling, since local-path ignores PVC sizes (§6.4) — and WAL-archive failure (§7.5). Neither
   is covered today; both are accepted risk until monitoring lands.
5. **§4's layout tree** gains the new directories and files from §5.2.
6. **New `docs/authentik-runbook.md`**: first-admin flow, restore drill procedure and output, the
   do-not-rotate `AUTHENTIK_SECRET_KEY` note, and the open sub-project 3 decision so it is not lost
   between sessions.

### 11.1 Deliberate placeholders

**None.** Every value in this document is concrete. The one value that had been left open — the
`ghcr.io/cloudnative-pg/postgresql` tag in §6.2 — was resolved by querying GHCR rather than guessed,
and the bucket name and region in §7.1 were resolved the same way (§7.1 explains why the region in
particular had to be measured and not remembered).

---

## 12. Deferred, with the trigger that promotes it

| Item | Why not now | Trigger |
|---|---|---|
| General PV backups (`30-backup` stage, restic → object store) | §4 A7 override, recorded in §11 | Any other workload with data that is not a Postgres database |
| Populating users and groups | Sub-project 3; mechanism is an open decision below | First real user needing titan's IdP |
| Outpost cutover for casa / techdelivery apps | Sub-project 4; needs 3 | First app moving to titan's IdP |
| Retiring the two old authentiks | Sub-project 5 | Sub-project 4 complete for that cluster |
| authentik blueprints as declarative config | Speculative until the import mechanism is chosen | Sub-project 3 |
| Monitoring (kube-prometheus-stack, disk + WAL-archive alerts) | Not in scope; titan has no Prometheus | Now overdue — see §11.4 |
| A second Postgres instance / HA | One node; a replica has nowhere to live | A second node |
| `s3-backup-secrets` rotation schedule, and an expiry reminder for the IAM key | No rotation precedent in either sibling; a silently expired key is §7.5's new trigger | First quarter of operation |

### 12.1 The open decision: how users and groups arrive

Recorded here so it is not re-derived from scratch later. titan starts empty (§3), so its user
directory has to be built. Two mechanisms, both viable, not mutually exclusive:

- **Blueprint export.** `ak export_blueprint` from casa's worker emits users and groups as
  declarative YAML that can then live in git — which fits this repo's premise better than anything.
  But write-only fields are omitted by design, so **passwords do not travel**. A blueprint can
  *set* a password (`attrs.password`), never copy one. Import therefore means "users exist, each
  sets a new password".
- **OAuth source federation.** Add casa's authentik as an OAuth source in titan's. Since 2024.8
  OAuth sources sync groups by default when a `groups` claim is present, so users and groups land
  automatically on first login **with passwords intact**. Cost: casa's IdP stays alive as a login
  dependency, and anyone who never logs in during the window is never migrated.

The choice is the operator's; it does not block this spec, and nothing here forecloses either.

---

## 13. Decision record

| # | Decision | Choice |
|---|---|---|
| D1 | Scope | Sub-project 1 only: authentik + shared Postgres + its backup path. PVC backups, user import, cutover and retirement stay separate specs. |
| D2 | Seed | Neither existing instance — titan starts empty; providers rebuilt deliberately; no forced version pin |
| D3 | Postgres platform | CloudNativePG `0.29.1` / operator `1.30.1`, one `Cluster` shared by all titan workloads |
| D4 | Declarative DB/roles | `Database` + `DatabaseRole` CRDs, authored next to each app, in the Cluster's namespace |
| D5 | Role credential | Operator-authored, sops-encrypted, referenced by `passwordSecret`; not generated by CNPG |
| D6 | Redis | Not deployed — authentik removed it in 2025.10 |
| D7 | Cross-namespace secret replication | Reflector `10.0.46`, promoted from bootstrap §9, scoped to TLS material only |
| D8 | Certificate placement | Moved to namespace `certificates`; reflected into `apps` and `auth`; free only because zero Ingresses exist today |
| D9 | Database backup | `barmanObjectStore` → AWS S3 `k8s-titan-pg-562256260016-eu-west-1-an` in `eu-west-1`, WAL archiving continuous, `ScheduledBackup` daily, `retentionPolicy: 30d`, no `endpointURL` |
| D10 | Backup credential | Dedicated IAM user `k8s-titan-pg-backups` whose policy names only that bucket; not the host's `titan/minio_env`. Bucket policy must whitelist `arn:aws:iam::562256260016:root` — a principal-scoped deny without root in the list locks the account owner out of the bucket permanently (§7.3) |
| D11 | Restore | Never in-place in CNPG; a scratch `Cluster` via `bootstrap.recovery`, scripted in `scripts/restore-drill.sh`, run once as part of done |
| D12 | Storage | Keep `local-path`; treat the PVC size as documentation; the real boundary is `vg0/pvc` (240 G ext4, online-growable via LVM) |
| D13 | Prune protection | `kustomize.toolkit.fluxcd.io/prune: disabled` on the `Cluster` — deleting the YAML must not delete the database |
| D14 | Secret handling in the chart | Plaintext non-secret values + one sops Secret via `global.envFrom`; not `existingSecret`, not a values blob |
| D15 | New offline gate | `make release-secrets`, non-vacuous by the `secrets-present` rule |
