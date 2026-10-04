# Implementation Plan — authentik on shared CloudNativePG (titan)

**Spec:** `docs/superpowers/specs/2026-10-03-titan-authentik-cnpg-design.md`
**Branch:** `feat/authentik-cnpg`
**Date:** 2026-10-03

Every value below is concrete and verified. Where a value could only be checked against a live
registry, the check that produced it is stated inline, because "it looked right" is how a wrong
region ends up silently filling a disk (§spec 7.1).

## Execution split

The operator does everything that touches the live cluster or holds a private key:

- AWS: bucket, IAM user, access key, bucket policy (spec §9.3).
- sops: authoring and encrypting the three Secrets with the `titan-k8s` age key.
- `kubectl` against `titan` with an admin context, and the restore drill.

The manifests, gates, scripts and docs are authored here and reach the cluster only through a merged
PR to `main`. Nothing in this plan applies a manifest to the cluster by hand.

## Order and why

Tasks 1–4 and 6 are mergeable with **no** AWS or sops prerequisite. Task 5 and 7 need the AWS bucket
and the encrypted Secrets to exist, so they are the merge gate. Task 8 needs 5 and 7. Task 9 needs
the cluster live. Do not reorder: the `dependsOn` chain means a red `infra` stage blocks everything
downstream, so a half-prerequisite merge turns `certificates` and `apps` red for a reason unrelated
to their own content.

---

## Task 1 — `make release-secrets` gate

**Files:** `Makefile`

A typo'd Secret name in a HelmRelease is a red release three time zones away. Moving live-cluster
failures onto the laptop is this repo's whole thesis, so the gate ships before the first release
that could have the typo.

Add to `.PHONY` (line 7):

```make
.PHONY: check check-ci kustomize-check validate update-keys scan leak-check secrets-placement secrets-present secrets-list release-secrets
```

Add to `check`'s prerequisites:

```make
check: leak-check kustomize-check validate secrets-placement release-secrets
```

Add to `check-ci`'s loop:

```make
	for t in leak-check kustomize-check secrets-placement release-secrets; do \
```

Append the target:

```make
# Every Secret a HelmRelease reaches for must exist in apply/10-secrets with a
# matching namespace. Without this gate a typo'd Secret name is a red HelmRelease
# three time zones away - the exact class of failure this repo exists to move onto
# the laptop (authentik spec S10.1).
#
# Scope is deliberately narrow: `spec.valuesFrom[].name` and
# `spec.values...envFrom[].secretRef.name`. Ingress `secretName:` is NOT scanned,
# because those Secrets are produced in-cluster by cert-manager and Reflector and
# never appear under apply/10-secrets - scanning them would fail forever.
#
# Non-vacuous by the same rule as secrets-present: zero HelmReleases is a FAIL.
#
# The scanner is awk, not a YAML parser: this gate must run in CI with no network
# and no extra packages. FNR==1 is load-bearing - without it awk carries state
# across files and a HelmRelease at the top of one file inherits the previous
# file's namespace, which silently retargets every reference it checks.
release-secrets:
	@joined=$$( \
	  find apply -name '*.yaml' ! -name kustomization.yaml -print0 | sort -z | xargs -0 awk ' \
	    FNR==1 { flushdoc() } \
	    /^---[ \t]*$$/ { flushdoc(); next } \
	    /^kind:[ \t]*HelmRelease[ \t]*$$/ { hr++; nhr++ } \
	    /^metadata:[ \t]*$$/ { inm=1; next } \
	    inm { if ($$1=="namespace:" && ns=="") { ns=$$2; inm=0 } else if ($$0 ~ /^[^ \t]/) inm=0 } \
	    /^  valuesFrom:[ \t]*$$/ { vf=1; next } \
	    vf && /^  [^ -]/ { vf=0 } \
	    vf && /^ +name:[ \t]*/ { r[++n]=$$2 } \
	    /^ *- *secretRef:[ \t]*$$/ { sr=1; next } \
	    sr && /^ +name:[ \t]*/ { r[++n]=$$2; sr=0 } \
	    END { flushdoc(); print "N\t" nhr+0 } \
	    function flushdoc(  i) { if (hr && ns != "") for (i = 1; i <= n; i++) print "R\t" ns "\t" r[i]; \
	                             hr=0; ns=""; n=0; vf=0; sr=0; inm=0 } \
	  '; \
	  find apply/10-secrets \( -name '*.yaml' -o -name '*.yml' \) ! -name kustomization.yaml -print0 | sort -z | xargs -0 -r awk ' \
	    FNR==1 { flushdoc() } \
	    /^---[ \t]*$$/ { flushdoc(); next } \
	    /^kind:[ \t]*/ { kind=$$2 } \
	    /^metadata:[ \t]*$$/ { inm=1; next } \
	    inm { if ($$1=="name:" && nm=="") nm=$$2; \
	          else if ($$1=="namespace:") { ns=$$2; inm=0 } \
	          else if ($$0 ~ /^[^ \t]/) inm=0 } \
	    END { flushdoc() } \
	    function flushdoc() { if (kind=="Secret" && nm!="" && ns!="") print "H\t" ns "\t" nm; kind=""; nm=""; ns=""; inm=0 } \
	  ' \
	); \
	n=$$(printf '%s\n' "$$joined" | awk -F'\t' '$$1=="N"{c=$$2} END{print c+0}'); \
	if [ "$$n" -eq 0 ]; then \
	  echo "FAIL: no HelmRelease found under apply/ - release-secrets cannot pass vacuously"; exit 1; fi; \
	missing=$$(printf '%s\n' "$$joined" | awk -F'\t' ' \
	  $$1=="H" { have[$$2 "\t" $$3]=1; next } \
	  $$1=="R" { w[++cnt]=$$2 "\t" $$3; next } \
	  END { for (i=1; i<=cnt; i++) if (!(w[i] in have)) { split(w[i], a, "\t"); print a[1] "/" a[2] } }'); \
	if [ -n "$$missing" ]; then echo "FAIL: HelmRelease references Secrets absent from apply/10-secrets:"; printf '%s\n' "$$missing" | sed 's/^/  /'; exit 1; fi; \
	echo "release-secrets: $$n HelmRelease(s) scanned; every referenced Secret present with a matching namespace"
```

**Its honest limit goes in the comment above, not in a commit message:** it proves a name and
namespace exist in the tree, **not** that the keys inside are the ones the chart wants.

### Verify

```bash
make release-secrets
```

Expected on the current tree: `release-secrets: 2 HelmRelease(s) scanned; every referenced Secret
present with a matching namespace`.

Red case — drop a probe HelmRelease in `apply/50-apps/_probe/p.yaml` in namespace `auth` referencing
`does-not-exist` via `valuesFrom` and `ovh-domain-secrets` via `global.envFrom[].secretRef`:

```
FAIL: HelmRelease references Secrets absent from apply/10-secrets:
  auth/does-not-exist
  auth/ovh-domain-secrets
```

Both lines must appear: the first proves `valuesFrom` is scanned, the second proves `secretRef` is
scanned **and** that a right-name-wrong-namespace reference is caught. Delete the probe afterwards.

---

## Task 2 — namespaces and Reflector

**Files:** `apply/00-bootstrap/namespaces.yaml`, `apply/20-infra/reflector/reflector.yaml`,
`apply/20-infra/kustomization.yaml`

Append four namespaces to `namespaces.yaml`, same shape as the two already there:

```yaml
---
apiVersion: v1
kind: Namespace
metadata:
  name: certificates
  labels:
    name: certificates
  annotations:
    kubernetes.io/description: "Certificates issued by cert-manager; the source of reflected TLS secrets"
---
apiVersion: v1
kind: Namespace
metadata:
  name: databases
  labels:
    name: databases
  annotations:
    kubernetes.io/description: "CloudNativePG clusters and their declarative databases and roles"
---
apiVersion: v1
kind: Namespace
metadata:
  name: auth
  labels:
    name: auth
  annotations:
    kubernetes.io/description: "authentik - the identity provider other clusters will federate against"
---
apiVersion: v1
kind: Namespace
metadata:
  name: cnpg-system
  labels:
    name: cnpg-system
  annotations:
    kubernetes.io/description: "CloudNativePG operator"
```

`apply/20-infra/reflector/reflector.yaml`:

```yaml
# Reflector replicates TLS material across namespaces and nothing else. The database
# credential is authored instead (spec 4 A4); keeping Reflector's scope to certificates
# is what stops it becoming a second secret-sync mechanism by accident.
#
# This is bootstrap spec 9's deferred item, promoted on its own stated trigger ("a second
# namespace needs titan-tls"), and promoted whole: the Certificate moves to `certificates`
# in the same slice (spec 5.3), so `apps` stops being the cluster's certificate source.
apiVersion: source.toolkit.fluxcd.io/v1
kind: HelmRepository
metadata:
  name: emberstack
  namespace: apps
spec:
  interval: 1h
  url: https://emberstack.github.io/helm-charts
---
apiVersion: helm.toolkit.fluxcd.io/v2
kind: HelmRelease
metadata:
  name: reflector
  namespace: apps
spec:
  releaseName: reflector
  chart:
    spec:
      chart: reflector
      version: "10.0.46"
      sourceRef:
        kind: HelmRepository
        name: emberstack
  interval: 30m
  driftDetection:
    mode: enabled
  install:
    strategy:
      name: RetryOnFailure
      retryInterval: 5m
  upgrade:
    strategy:
      name: RetryOnFailure
      retryInterval: 5m
```

The HelmRepository lives in `apps` because a Flux source must share a namespace with the
HelmReleases that consume it.

Add to `apply/20-infra/kustomization.yaml`:

```yaml
  - reflector/reflector.yaml
```

### Verify

```bash
kubectl kustomize apply/20-infra | grep -c 'kind: HelmRelease'      # 4 (cert-manager, ovh-webhook, reflector, +cnpg after task 3)
kubectl kustomize apply/00-bootstrap | grep -c 'kind: Namespace'    # 6
make kustomize-check
```

Live, after merge: `kubectl -n apps get helmrelease reflector` → `Ready=True`, and
`kubectl -n apps get deploy reflector`.

---

## Task 3 — CloudNativePG operator

**Files:** `apply/20-infra/cnpg/operator.yaml`, `apply/20-infra/kustomization.yaml`

Chart `0.29.1` (operator `1.30.1`) — verified: the GHCR tag list for
`cloudnative-pg/charts/cloudnative-pg` contains `0.29.1`. OCI rather than a HelmRepository, matching
this repo's cert-manager release rather than adding a second source type for no reason.

```yaml
# CloudNativePG operator. Chosen over a hand-written StatefulSet because the databases
# must be declarative: a Database and a DatabaseRole are manifests a reviewer can read,
# where 'kubectl exec psql -c CREATE ROLE' is not (spec 4 A4/A5).
#
# CRDs ship as chart TEMPLATES (templates/crds/crds.yaml), not in a crds/ directory, so
# Flux manages them as ordinary resources and `install.crds: CreateReplace` - which is
# what the cert-manager release above needs - would be a no-op here. They carry
# helm.sh/resource-policy: keep, so an uninstall does not drop the CRDs and orphan every
# Cluster in the tree.
#
# The webhook is failurePolicy: Fail. While the operator is down, edits to any cnpg CR
# are rejected cluster-wide. That is correct behaviour, but it means an operator outage
# is also 'cannot change a database password', not only 'no new databases'.
apiVersion: source.toolkit.fluxcd.io/v1
kind: OCIRepository
metadata:
  name: cloudnative-pg
  namespace: cnpg-system
spec:
  interval: 5m
  url: oci://ghcr.io/cloudnative-pg/charts/cloudnative-pg
  layerSelector:
    mediaType: "application/vnd.cncf.helm.chart.content.v1.tar+gzip"
    operation: copy
  ref:
    semver: "0.29.1"
---
apiVersion: helm.toolkit.fluxcd.io/v2
kind: HelmRelease
metadata:
  name: cloudnative-pg
  namespace: cnpg-system
spec:
  releaseName: cloudnative-pg
  chartRef:
    kind: OCIRepository
    name: cloudnative-pg
  interval: 30m
  driftDetection:
    mode: enabled
  install:
    strategy:
      name: RetryOnFailure
      retryInterval: 5m
  upgrade:
    strategy:
      name: RetryOnFailure
      retryInterval: 5m
```

Add to `apply/20-infra/kustomization.yaml`:

```yaml
  - cnpg/operator.yaml
```

### Verify

```bash
kubectl kustomize apply/20-infra | grep -c 'kind: HelmRelease'   # 4
make kustomize-check
```

Live: `kubectl -n cnpg-system get helmrelease cloudnative-pg` → `Ready=True`;
`kubectl api-resources | grep cnpg.io` lists `clusters`, `databases`, `databaseroles`,
`scheduledbackups`, `backups`.

The `infra` stage has `wait: true`, so it does not go Ready until the operator does. That is the
free part of the existing `dependsOn` chain — and its honest price: if this release fails, nothing in
`certificates` or `apps` deploys at all.

---

## Task 4 — the shared cluster

**Files:** `apply/50-apps/databases/postgres.yaml`, `apply/50-apps/kustomization.yaml`

```yaml
# The one Postgres every titan workload shares. One instance on one node is the normal
# shape, not a compromise: there is no second node to place a replica on, and any
# minSyncReplicas above zero would be unsatisfiable (spec 6.2).
apiVersion: postgresql.cnpg.io/v1
kind: Cluster
metadata:
  name: postgres
  namespace: databases
  annotations:
    # THE ONE ANNOTATION THAT MATTERS. The apps stage runs with prune: true, so without
    # this, deleting postgres.yaml from git - a bad rebase, a mis-scoped revert, a git rm
    # during a reorganisation - deletes the Cluster, and CNPG deletes a Cluster's PVCs with
    # it. That is the identity database of every service that will ever point at it
    # (spec 6.3). Deleting it must require a deliberate `kubectl delete cluster postgres`.
    kustomize.toolkit.fluxcd.io/prune: disabled
spec:
  instances: 1
  # Pinned explicitly so a later operator bump cannot silently move the Postgres major
  # version. 18.6 verified against GHCR: manifest fetch returns 200 for 18.6 and 404 for
  # 18.5, 18.7 and 99.9. Operator 1.30.x supports Postgres 14-18.
  imageName: ghcr.io/cloudnative-pg/postgresql:18.6
  storage:
    # A label, not a limit. local-path on k3s ignores the requested size; the real ceiling
    # is the 240G vg0/pvc ext4 mount, and its reclaimPolicy is Delete (spec 6.4). Sizing
    # here documents intent and nothing more.
    size: 10Gi
    storageClass: local-path
  resources:
    requests:
      cpu: 100m
      memory: 256Mi
    limits:
      cpu: "1"
      memory: 1Gi
```

Add to `apply/50-apps/kustomization.yaml`, replacing `resources: []` and its comment:

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - databases/postgres.yaml
```

### Verify

```bash
kubectl kustomize apply/50-apps | grep -A3 'kind: Cluster'
kubectl kustomize apply/50-apps | grep 'prune: disabled'
make kustomize-check
```

The prune annotation must be present in the **built** output, not just the source — kustomize has
ways of dropping things.

Live: `kubectl -n databases get cluster postgres` → `Healthy`, `1/1`.

---

## Task 5 — the S3 backup path

**Prerequisite (operator):** bucket `k8s-titan-pg-562256260016-eu-west-1-an` in **`eu-west-1`**,
IAM user `k8s-titan-pg-backups` with the spec §7.3 policy and an access key, the three-statement
bucket policy with **root whitelisted**, Block Public Access on, SSE-S3 default encryption,
versioning on. Verify before wiring the cluster to it:

```bash
aws s3api get-bucket-location --bucket k8s-titan-pg-562256260016-eu-west-1-an   # LocationConstraint eu-west-1
aws s3 ls s3://k8s-titan-pg-562256260016-eu-west-1-an --region eu-west-1        # not AccessDenied
```

The region check is not ceremony. The bucket name says `eu-west-1` and the operator initially said
`us-west-1`; `curl -I` on the bucket returns `x-amz-bucket-region: eu-west-1` with a 307. A wrong
region does not fail loudly — every WAL archive fails behind a redirect while Postgres reports
itself healthy, which is precisely the §7.5 disk-fill failure.

**Files:** `apply/10-secrets/s3-backup-secrets.yaml`, `apply/10-secrets/kustomization.yaml`,
`apply/50-apps/databases/postgres.yaml`, `apply/50-apps/databases/postgres-backup.yaml`,
`apply/50-apps/kustomization.yaml`

Plaintext staging, then the documented encrypt flow (the gitignored name is what keeps `git add -A`
from ever staging plaintext, and sops picks recipients from the file's own path):

```bash
export SOPS_AGE_KEY_FILE=$HOME/.config/sops/age/titan-k8s-key.txt
stage=apply/10-secrets/.staging.s3-backup.yaml
cat > "$stage" <<'EOF'
apiVersion: v1
kind: Secret
metadata:
  name: s3-backup-secrets
  namespace: databases
type: Opaque
stringData:
  ACCESS_KEY_ID: "<from aws iam create-access-key>"
  SECRET_ACCESS_KEY: "<from aws iam create-access-key>"
  AWS_REGION: eu-west-1
EOF
sops --encrypt --in-place "$stage"
mv "$stage" apply/10-secrets/s3-backup-secrets.yaml
```

`AWS_REGION` is in the Secret because the CRD puts it there: `s3Credentials.region` is a
secret-key reference — *"the reference to the secret containing the region name"* — not a plain
field. There is no EC2 instance metadata on titan for barman to fall back to, so the region is
required, not optional.

Append to `apply/10-secrets/kustomization.yaml`:

```yaml
  - s3-backup-secrets.yaml
```

Extend the `Cluster` spec from Task 4:

```yaml
  backup:
    barmanObjectStore:
      destinationPath: s3://k8s-titan-pg-562256260016-eu-west-1-an
      # No endpointURL. Setting one is what you do for an S3-compatible store; against real
      # AWS it is at best redundant and at worst a second thing to get wrong.
      s3Credentials:
        accessKeyId:     {name: s3-backup-secrets, key: ACCESS_KEY_ID}
        secretAccessKey: {name: s3-backup-secrets, key: SECRET_ACCESS_KEY}
        region:          {name: s3-backup-secrets, key: AWS_REGION}
      # CRD pattern is ^[1-9][0-9]*[dwm]$ - '30d', NOT '30 days'. CNPG enforces retention
      # through barman-cloud-backup-delete with these same credentials, so an S3 lifecycle
      # rule is a backstop for noncurrent versions, not retention. Do not let anyone later
      # consolidate the two and lose retention.
      retentionPolicy: 30d
```

`apply/50-apps/databases/postgres-backup.yaml`:

```yaml
# The daily base backup. WAL archiving is continuous and implicit the moment a
# barmanObjectStore exists, so this file is only the base-backup schedule - the WAL
# between 03:00 and the failure is already shipped (spec 7.1).
apiVersion: postgresql.cnpg.io/v1
kind: ScheduledBackup
metadata:
  name: postgres-daily
  namespace: databases
spec:
  schedule: "0 3 * * *"
  method: barmanObjectStore
  # 'self' keeps the backups owned by this ScheduledBackup, so pruning the schedule does
  # not prune the backups it produced.
  backupOwnerReference: self
  cluster:
    name: postgres
```

Append to `apply/50-apps/kustomization.yaml`:

```yaml
  - databases/postgres-backup.yaml
```

### Verify

```bash
make release-secrets        # must now report databases/s3-backup-secrets as present, not missing
make validate
kubectl kustomize apply/50-apps | grep -E 'destinationPath|retentionPolicy|AWS_REGION'
```

Live:

```bash
kubectl -n databases get cluster postgres -o jsonpath='{.status.conditions}'   # no BackupWalFailed
kubectl -n databases get scheduledbackup,backup
kubectl -n databases get cluster postgres -o jsonpath='{.status.timelineID}'
aws s3 ls s3://k8s-titan-pg-562256260016-eu-west-1-an --region eu-west-1        # postgres/base/ and postgres/wals/
```

That last line is the one that matters. S3 failures produce no error anywhere else — that is the
lesson titan's etcd snapshot already paid for, and the reason the drill in Task 9 exists.

---

## Task 6 — move the Certificate to `certificates`

**Files:** `apply/40-certificates/titan-wildcard.yaml`

This is free **now** and expensive later. Nothing consumes `titan-tls` today — `apply/50-apps` is
empty, so not one Ingress points at it. Flux creates the new object and prunes the old; deleting the
old Certificate deletes `apps/titan-tls`; Reflector repopulates it by auto-reflection inside the same
reconcile. One reconcile window, zero traffic. Doing this after ten services sit behind that
certificate is a live TLS cutover.

```yaml
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: titan-wildcard
  namespace: certificates
spec:
  secretName: titan-tls
  issuerRef:
    kind: ClusterIssuer
    name: le-prod-titan
  commonName: titan.arrieta.eu
  dnsNames:
    - titan.arrieta.eu
    - "*.titan.arrieta.eu"
  secretTemplate:
    annotations:
      reflector.v1.k8s.emberstack.com/reflection-allowed: "true"
      reflector.v1.k8s.emberstack.com/reflection-allowed-namespaces: "apps,auth"
      reflector.v1.k8s.emberstack.com/reflection-auto-enabled: "true"
      reflector.v1.k8s.emberstack.com/reflection-auto-namespaces: "apps,auth"
```

Auto-reflection means Reflector creates the destination Secret itself — no placeholder object in
`apps` or `auth`, which is the thing that would have needed hand-maintaining.

**This is the one task that contradicts AGENTS.md**, which says TLS for any Ingress is
`secretName: titan-tls` in namespace `apps`. Task 10 amends AGENTS.md in the same PR; do not leave
the contradiction standing.

### Verify

```bash
kubectl kustomize apply/40-certificates | grep -A2 'namespace: certificates'
make kustomize-check
```

Live:

```bash
kubectl -n certificates get certificate titan-wildcard    # Ready=True
kubectl -n apps get secret titan-tls                       # reflected, owner is Reflector
kubectl -n auth get secret titan-tls                       # reflected
```

If `auth/titan-tls` never appears, the annotations are the cause — check all four are on the
**Secret**, not the Certificate. cert-manager copies `secretTemplate.annotations` onto the Secret it
produces; a typo there is invisible in the Certificate's own status.

---

## Task 7 — authentik's database and role

**Prerequisite:** Task 5's operator-side setup, plus the two authentik Secrets.

**Files:** `apply/10-secrets/authentik-secrets.yaml`, `apply/10-secrets/kustomization.yaml`,
`apply/50-apps/auth/authentik-db.yaml`, `apply/50-apps/kustomization.yaml`

```bash
export SOPS_AGE_KEY_FILE=$HOME/.config/sops/age/titan-k8s-key.txt
stage=apply/10-secrets/.staging.authentik.yaml
SECRET_KEY=$(openssl rand -base64 32)
DB_PASS=$(openssl rand -base64 24)
cat > "$stage" <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: authentik-secrets
  namespace: auth
type: Opaque
stringData:
  AUTHENTIK_SECRET_KEY: "$SECRET_KEY"
  AUTHENTIK_POSTGRESQL__PASSWORD: "$DB_PASS"
---
apiVersion: v1
kind: Secret
metadata:
  name: authentik-db-credentials
  namespace: databases
  type: kubernetes.io/basic-auth
stringData:
  username: authentik
  password: "$DB_PASS"
EOF
sops --encrypt --in-place "$stage"
mv "$stage" apply/10-secrets/authentik-secrets.yaml
```

Two things that look wrong here and are not:

- **The same password appears twice in one file.** `DatabaseRole` needs it to `ALTER ROLE`, authentik
  needs it to connect, and Reflector is deliberately scoped to TLS only (spec §5.3) so it cannot carry
  the credential across namespaces. Duplicating one value inside one sops file is cheaper than
  widening Reflector's scope to secrets. If they ever drift, authentik gets
  `password authentication failed` and the HelmRelease goes red — loud, not silent.
- **`DatabaseRole` has no `managePassword` field.** It takes `passwordSecret`, and the Secret must be
  `kubernetes.io/basic-auth`. The `cnpg.io/reload: "true"` label on the role (in git, not here) is
  what makes CNPG re-apply the password when the Secret changes.

`DatabaseRole` lives in git, unencrypted — it references the Secret by name and holds no secret. The
staging file above holds the two Secrets and nothing else; putting a `DatabaseRole` in both places
makes CNPG reject the duplicate.
`apply/50-apps/auth/authentik-db.yaml`:

```yaml
# The database and the role, authored next to the app that owns them, so a reviewer sees
# the whole dependency in one directory (spec 4 A4/A5). Both live in `databases`: a CNPG
# Database must share a namespace with its Cluster.
apiVersion: postgresql.cnpg.io/v1
kind: Database
metadata:
  name: authentik
  namespace: databases
spec:
  name: authentik
  owner: authentik
  cluster:
    name: postgres
---
apiVersion: postgresql.cnpg.io/v1
kind: DatabaseRole
metadata:
  name: authentik
  namespace: databases
  labels:
    cnpg.io/reload: "true"
spec:
  name: authentik
  cluster:
    name: postgres
  passwordSecret:
    name: authentik-db-credentials
```

The `DatabaseRole` is declared twice — once in `10-secrets` (encrypted, because it is the only place
the password can be referenced from) and once here. **Keep only the one in `authentik-db.yaml`.** The
staging-file copy above exists only so the operator can see the shape while authoring; the committed
`authentik-secrets.yaml` holds the two Secrets and the `DatabaseRole` lives in git unencrypted, where
a reviewer can read it. If both are committed CNPG rejects the duplicate.

Append to `apply/10-secrets/kustomization.yaml`:

```yaml
  - authentik-secrets.yaml
```

Append to `apply/50-apps/kustomization.yaml`:

```yaml
  - auth/authentik-db.yaml
```

### Verify

```bash
make release-secrets
make validate
kubectl kustomize apply/50-apps | grep -c 'kind: DatabaseRole'   # exactly 1
kubectl kustomize apply/10-secrets | grep -c 'kind: Secret'      # 4 (ovh, s3-backup, authentik-secrets, authentik-db-credentials)
```

Live:

```bash
kubectl -n databases get database,databaserole          # both Synced
kubectl -n databases exec postgres-1 -c postgres -- psql -U postgres -c '\du authentik'
kubectl -n databases exec postgres-1 -c postgres -- psql -U postgres -lqt | cut -d'|' -f1 | grep -w authentik
```

The `Database` may report `Reconciling` briefly before the role exists — Flux applies the two CRs in
file order and CNPG retries. It must converge; if it is still not `Synced` after a minute, that is a
real failure, not a race.

---

## Task 8 — authentik itself

**Files:** `apply/50-apps/auth/authentik.yaml`, `apply/50-apps/kustomization.yaml`

Chart `2026.8.3` — verified by pulling it: `Chart.yaml` gives `appVersion: 2026.8.3`, and
`grep -ci redis values.yaml` returns **0**. Redis was removed in authentik 2025.10; a `redis:` block
in values would be dead weight that reads as if something needed it.

```yaml
apiVersion: source.toolkit.fluxcd.io/v1
kind: HelmRepository
metadata:
  name: authentik-repo
  namespace: auth
spec:
  interval: 12h
  url: https://charts.goauthentik.io
---
apiVersion: helm.toolkit.fluxcd.io/v2
kind: HelmRelease
metadata:
  name: authentik
  namespace: auth
spec:
  releaseName: authentik
  interval: 30m
  timeout: 10m
  chart:
    spec:
      chart: authentik
      version: "2026.8.3"
      sourceRef:
        kind: HelmRepository
        name: authentik-repo
  driftDetection:
    mode: enabled
  install:
    strategy:
      name: RetryOnFailure
      retryInterval: 5m
  upgrade:
    strategy:
      name: RetryOnFailure
      retryInterval: 5m
  values:
    authentik:
      log_level: info
      error_reporting:
        # Sends stack traces to authentik's own Sentry. Opt-in, and off here.
        enabled: false
      listen:
        # 2026.8 is a breaking change: forwarded headers (X-Forwarded-For/-Proto/-Host) are
        # honoured ONLY from listed CIDRs. Get this wrong and HTTPS is interpreted as HTTP -
        # blocked mixed content, an endless spinner, or an auth error, with nothing in the logs.
        #
        # Two traps, both checked against the docs rather than assumed:
        #   * the format is a COMMA-SEPARATED STRING, not a JSON list. authentik's own fix
        #     (goauthentik/authentik#8075) says the format is '127.0.0.0/8,::1/128' and
        #     explicitly not '["127.0.0.0/8","::1/128"]'.
        #   * setting this REPLACES the defaults, which already include 10.0.0.0/8 - and
        #     titan's pod CIDR 10.62.0.0/16 sits inside it. So not setting it at all would
        #     work. This is a deliberate tightening, which is why loopback rides along:
        #     without 127.0.0.0/8, `kubectl port-forward` debugging gets no forwarded headers.
        trusted_proxy_cidrs: "10.62.0.0/16,127.0.0.0/8"
      web:
        path: /
        # Recommended now, REQUIRED in 2026.11. Free to set today, removes an upgrade surprise.
        base_url: https://auth.titan.arrieta.eu/
      postgresql:
        # CNPG's read-write service. The chart's own default is '{{ .Release.Name }}-postgresql',
        # i.e. the bundled subchart we are not using.
        host: postgres-rw.databases.svc.cluster.local
        port: 5432
        name: authentik
        user: authentik
        # password deliberately absent - empty values are skipped by the chart's env helper,
        # so it comes from the Secret below and nothing else can shadow it.
    global:
      envFrom:
        - secretRef:
            name: authentik-secrets
    postgresql:
      # The bundled Bitnami subchart. Off: the database is the shared CNPG Cluster.
      enabled: false
    server:
      replicas: 1
      service:
        type: ClusterIP
      ingress:
        enabled: true
        ingressClassName: traefik
        hosts:
          - auth.titan.arrieta.eu
        tls:
          - hosts:
              - auth.titan.arrieta.eu
            # Reflector's copy of the Certificate from `certificates` (Task 6). Not created
            # by this release, and NOT checked by make release-secrets - the gate scans
            # valuesFrom and envFrom.secretRef, never ingress secretName, on purpose.
            secretName: titan-tls
    worker:
      replicas: 1
```

There is deliberately **no `valuesFrom`** here. Flux's default `valuesKey` is `values.yaml`, and a
Secret reference without that key makes the HelmRelease fail with *key not found* — so a
`valuesFrom: Secret` pointing at `authentik-secrets` would turn the release red for a reason that
looks like a Flux bug. `global.envFrom` is the chart's own mechanism for injecting environment
variables from a Secret, and it is the only one used. `make release-secrets` scans
`global.envFrom[].secretRef.name` precisely so this form is still covered; it does not require
`valuesFrom` to exist.

Append to `apply/50-apps/kustomization.yaml`:

```yaml
  - auth/authentik.yaml
```

### Verify

Render offline against the pulled chart — this is the only check that proves the env actually lands
in **both** containers, and that the Ingress gets the right class, host and TLS secret:

```bash
cd /tmp && helm repo add authentik https://charts.goauthentik.io >/dev/null && helm repo update >/dev/null
helm pull authentik/authentik --version 2026.8.3 && tar xzf authentik-2026.8.3.tgz
python3 - <<'PY'
import yaml
docs = [d for d in yaml.safe_load_all(open('/home/coder/k8s-titan/apply/50-apps/auth/authentik.yaml')) if d]
hr = next(d for d in docs if d['kind'] == 'HelmRelease')
yaml.safe_dump(hr['spec']['values'], open('/tmp/akvals.yaml', 'w'))
PY
helm template authentik /tmp/authentik -f /tmp/akvals.yaml \
  -s templates/server/deployment.yaml -s templates/worker/deployment.yaml -s templates/server/ingress.yaml \
  | grep -nE '^kind:|envFrom:|secretRef:|name: authentik|secretName:|ingressClassName:|host:'
```

Note `-s templates/server/ingress.yaml` — the ingress template lives under `server/`, and pointing
`-s` at `templates/ingress.yaml` makes helm exit non-zero with a confusing "not found" while the
rest of the render looks fine.

Expected output, verified against the real chart:

```
4:kind: Deployment
6:  name: authentik-server
45:          envFrom:
46:            - secretRef:
47:                name: authentik
48:            - secretRef:
49:                name: authentik-secrets
109:kind: Deployment
111:  name: authentik-worker
151:          envFrom:
152:            - secretRef:
153:                name: authentik
154:            - secretRef:
155:                name: authentik-secrets
215:kind: Ingress
228:  ingressClassName: traefik
230:    - host: "auth.titan.arrieta.eu"
243:      secretName: titan-tls
```

The `envFrom` pair must appear **twice** — the chart's own config Secret first, ours second, so ours
wins on any shared key. A worker without the DB password crash-loops, and this grep is what catches
that before merge.

And decode the three values that are easy to get syntactically wrong:

```bash
helm template authentik /tmp/authentik -f /tmp/akvals.yaml -s templates/secret.yaml 2>/dev/null \
  | grep -E 'TRUSTED|BASE_URL|POSTGRESQL__HOST' | while read -r k v; do
      printf '%-40s %s\n' "${k%:}" "$(echo "$v" | tr -d '"' | base64 -d)"; done
```

```
AUTHENTIK_LISTEN__TRUSTED_PROXY_CIDRS    10.62.0.0/16,127.0.0.0/8
AUTHENTIK_POSTGRESQL__HOST               postgres-rw.databases.svc.cluster.local
AUTHENTIK_WEB__BASE_URL                  https://auth.titan.arrieta.eu/
```

If the first line shows `["10.62.0.0/16"]` instead, the comma-separated-string form was not used.

Also:

```bash
make release-secrets     # auth/authentik-secrets present
make validate
```

Live:

```bash
kubectl -n auth get helmrelease authentik                       # Ready
kubectl -n auth get pods                                        # server + worker Running
kubectl -n auth logs deploy/authentik-worker --tail=50
curl -sI https://auth.titan.arrieta.eu/ | head -1               # 200 or 302 to /if/
```

Then the human half, which is the real test of the trusted-proxy CIDR:

```
https://auth.titan.arrieta.eu/if/flow/initial-setup/
```

**Trailing slash required** — `Not Found` without it. Create `akadmin`, log out, log back in. That
login is the test: a wrong CIDR produces a redirect loop or a mixed-content block, far louder than
anything in the logs.

No admin password ever enters git. `AUTHENTIK_BOOTSTRAP_PASSWORD` exists and is deliberately unused:
it puts a plaintext password in a pod spec for no benefit, since the first login is a human act.

---

## Task 9 — restore drill and runbook

**Files:** `scripts/restore-drill.sh`, `docs/authentik-runbook.md`

CNPG recovery is **never in-place**: `bootstrap.recovery` builds a *new* cluster from a base backup
and replays WAL. So the drill is a scratch cluster beside the live one, and the live cluster is never
touched.

```bash
#!/usr/bin/env bash
# Restore drill for titan's CloudNativePG Postgres. See docs/authentik-runbook.md.
#
# CNPG never restores over a running cluster, so this builds a scratch Cluster from the
# object store and asserts the restored authentik database is real. The live cluster is
# read-only to this script - it never writes to it.
#
# Needs an admin kubeconfig. The read-only k8s-reader identity cannot run it and must not
# be able to.
#
# The scratch cluster is created ad hoc and never committed, so Flux neither owns nor
# prunes it. Committing it would put a second 10Gi PVC request in git and invite someone
# to "fix" the duplication later.
set -euo pipefail

NS=${NS:-databases}
DRILL=${DRILL:-postgres-drill}
IMAGE=${IMAGE:-ghcr.io/cloudnative-pg/postgresql:18.6}
BUCKET=${BUCKET:-k8s-titan-pg-562256260016-eu-west-1-an}
DELETE=${DELETE:-1}

command -v kubectl >/dev/null || { echo "kubectl not on PATH"; exit 1; }

echo "== preflight"
# A backup that has not completed is not a backup. Fail here rather than 15 minutes into
# a recovery that was never going to find a base backup.
kubectl -n "$NS" get backup -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.status.phase}{"\n"}{end}' \
  | grep -q Completed || { echo "FAIL: no Completed Backup in $NS - run 'kubectl -n $NS create backup manual --cluster postgres' and wait"; exit 1; }
kubectl -n "$NS" get cluster postgres -o jsonpath='{.status.conditions}' | grep -q '"type":"Healthy"' \
  || echo "WARN: source cluster postgres is not Healthy; continuing anyway"

echo "== creating scratch cluster $DRILL"
kubectl apply -f - <<EOF
apiVersion: postgresql.cnpg.io/v1
kind: Cluster
metadata:
  name: $DRILL
  namespace: $NS
spec:
  instances: 1
  imageName: $IMAGE
  storage:
    size: 10Gi
    storageClass: local-path
  bootstrap:
    recovery:
      barmanObjectStore:
        destinationPath: s3://$BUCKET
        s3Credentials:
          accessKeyId:     {name: s3-backup-secrets, key: ACCESS_KEY_ID}
          secretAccessKey: {name: s3-backup-secrets, key: SECRET_ACCESS_KEY}
          region:          {name: s3-backup-secrets, key: AWS_REGION}
EOF

trap '[ "$DELETE" = "1" ] && kubectl -n "$NS" delete cluster "$DRILL" --ignore-not-found || true' EXIT

echo "== waiting for $DRILL to become Healthy (recovery can take minutes)"
kubectl -n "$NS" wait --for=condition=Healthy cluster/"$DRILL" --timeout=20m

echo "== asserting the restored database is real"
# core_user is authentik's own user table. >=1 row means the database exists, migrations
# ran in the source, and the data survived the round trip through S3. Zero rows means the
# backup predates the first admin, which is a failure of the drill's timing, not of S3.
count=$(kubectl -n "$NS" exec "$DRILL-1" -c postgres -- \
  psql -U postgres -d authentik -Atc 'select count(*) from core_user')
echo "core_user rows in restored cluster: $count"
[ "$count" -ge 1 ] || { echo "FAIL: restored authentik database has no users"; exit 1; }

echo "PASS: restore drill complete - $DRILL recovered from s3://$BUCKET with $count users"
```

`chmod +x scripts/restore-drill.sh`.

`docs/authentik-runbook.md` covers, in this order: first-admin flow including the trailing slash;
the restore drill and **its recorded output from the first successful run**; the
`AUTHENTIK_SECRET_KEY` do-not-rotate note (it signs cookies and derives unique user IDs — changing
it invalidates sessions and user IDs, and the sops file is its only backup); the two backup
destinations and which credential opens each; and the open sub-project 3 decision (blueprint export
vs OAuth federation) so it is not re-derived from scratch next session.

### Verify

```bash
bash -n scripts/restore-drill.sh
shellcheck scripts/restore-drill.sh    # if installed; say so if not
```

Live, run once and paste the output into the runbook:

```bash
DELETE=1 ./scripts/restore-drill.sh 2>&1 | tee /tmp/restore-drill-$(date +%F).log
```

Definition of done for this slice: that log exists. A backup that has only ever been written is a
hope — the etcd snapshot in `nixos-configurations` failed silently for four nights because the
*manual* drill inherited credentials the scheduled unit never had.

---

## Task 10 — documentation reconciliation

**Files:** `AGENTS.md`, `docs/superpowers/specs/2026-10-03-k8s-titan-flux-bootstrap-design.md`,
`README.md`

`AGENTS.md`: the ingress line becomes "`titan-tls` is produced in `certificates` and reflected into
`apps` and `auth` by Reflector; reference it as `secretName: titan-tls` from the namespace your
Ingress lives in". Leaving the old sentence is leaving a lie in the file every future agent reads
first.

Bootstrap spec amendments (these are edits to it, not commentary beside it):

1. **D10 superseded** — Reflector promoted, Certificate in `certificates`, `titan-tls` reflected into
   `apps` and `auth`. Record why now: §9's own trigger fired, and moving while zero Ingresses consume
   the certificate is free.
2. **§7 becomes false in two places** — "No `secretTemplate` ships with titan's `Certificate`" and
   "Reflector is deferred". Rewrite both rather than delete, so the reasoning trail survives the
   reversal.
3. **§9 rows** — delete the Reflector row as promoted; keep the PV-backup row with the conscious
   override recorded (its trigger said "before any workload with data lands on titan", authentik is
   data, and the override is accepted because the database has its own backup path while the general
   restic stream stays deferred with its trigger intact).
4. **§9's monitoring row gets a sharper trigger** — "titan holds something worth alerting on" is now
   satisfied. The two metrics that matter are free space on `/var/lib/rancher/k3s/storage` (the real
   ceiling, since local-path ignores PVC sizes) and WAL-archive failure. Neither is covered; both are
   accepted risk until monitoring lands.
5. **§4's layout tree** gains the new directories and files.

`README.md`: the stage table gains the new namespaces, and the "what runs where" section names the two
backup destinations.

---

## Task 11 — post-merge verification

Operator, after merge to `main`:

```bash
kubectl -n flux-system get kustomization
kubectl -n cnpg-system get helmrelease cloudnative-pg
kubectl -n databases get cluster postgres
kubectl -n databases get database,databaserole
kubectl -n certificates get certificate titan-wildcard
kubectl -n apps get secret titan-tls && kubectl -n auth get secret titan-tls
kubectl -n auth get helmrelease authentik
kubectl -n databases get backup
```

Then Tasks 8's human half and Task 9's drill.

---

## The five failures this plan is built to prevent

Each maps to a check above, and each is a live-cluster failure moved onto the laptop:

1. **Deleting `postgres.yaml` deletes the database.** `prune: disabled` on the Cluster; Task 4 greps
   the *built* output for it, because kustomize can drop things and the annotation's whole job is to
   survive to the cluster.
2. **WAL archive failure fills `vg0/pvc`.** Unmitigated by any gate — recorded as accepted risk with
   its trigger named. The AWS move removed the `wg_titan` dependency and added an IAM key that can
   expire silently. Task 5's `aws s3 ls` and Task 9's drill are the only controls.
3. **Wrong trusted-proxy CIDR breaks authentik behind Traefik.** Task 8's values carry the
   comma-separated-string form (not JSON) and keep loopback, and the first-admin login is the test.
4. **Missing Reflector annotations means no `auth/titan-tls`.** Task 6 checks the annotations land on
   the Secret, and names the symptom (`auth/titan-tls` absent while the Certificate reads Ready).
5. **Invalid `retentionPolicy` is rejected by the CRD.** `30d`, matching `^[1-9][0-9]*[dwm]$`; Task 5
   greps the built output so a `30 days` cannot reach the API server.

Plus the gate that catches the class rather than the instance: `make release-secrets` fails on a
missing or wrong-namespace Secret reference, and fails on zero HelmReleases so it cannot pass
vacuously.

## Out of scope

General PVC backups, user and group import (sub-project 3, mechanism still open), outpost cutover for
casa and techdelivery (sub-project 4), retiring the two existing authentiks (sub-project 5),
monitoring, HA. See spec §12 for each item's promotion trigger.
